require 'open-uri'
require 'numbers_in_words/duck_punch'

module ScotusAppsAndMotions

  # Since 2003
  JUSTICES = %w(Souter Kagan O'Connor Sotomayor Rehnquist Alito Roberts Breyer Ginsburg Thomas
    Kennedy Scalia Stevens)

  def chief date
    date < Date.new(2005,9,29) ? 'Rehnquist' : 'Roberts'
  end

  JUSTICE_REGEXP = (JUSTICES.map{|j| 'Justice ' + j} + ['The Chief Justice']).join('|')

  MONTHS = %w(January Jan February Feb March Mar April Apr May June Jun July Jul August Aug September Sep Sept October Oct November Nov December Dec)
  DATE_REGEXP = "(#{MONTHS.join('|')}) ([0-9]{1,2}),? ([0-9]{4})"

  def get term, number, application_or_motion = :application
    fail 'Only available since 2003 term' if term < 2003
    term = term.to_s[-2..-1]
    a_m = case application_or_motion
            when :application then 'a'
            when :motion then 'm'
            else fail ArgumentError,
               'application_or_motion must be :application (default) or :motion'
          end
    url = "http://www.supremecourt.gov/docketfiles/#{term}#{a_m}#{number}.htm"
    doc = Nokogiri::HTML(open(url))

    doc.traverse do |n|
      next unless n.text?
      new_n = Nokogiri::XML::Text.new(n.text.gsub(/[[:space:]]+/, ' ').gsub("\r\n", "\n"), doc)
      n.replace new_n
    end
    doc
  rescue OpenURI::HTTPError => e
    return nil if e.message == "404 Not Found"
    raise e
  end

  def parse doc
    return nil unless doc

    ret = parse_headers(doc)

    ret[:parties] = parse_parties(doc, ret)

    ret[:proceedings] = parse_proceedings(doc, ret)

    ret
  end

  private

  def parse_headers doc
    ret = {}

    ret[:id] = doc.title.split.last

    {:creation_date => 'creation_date', :docketed_date => 'Docketed'}.each do |k, v|
      date_string = doc.css("meta[name='#{v}']").first['content']
      unless date_string.empty?
        date = Date.parse(date_string) rescue Date.strptime(date_string, '%m/%d/%Y')
        ret[k] = date if date
      end
    end
    {:term => 'Term', :number => 'CaseNumber'}.each do |k,v|
      ret[k] = doc.css("meta[name='#{v}']").first['content'].to_i
    end
    {:type => 'CaseType', :petitioner => 'Petitioner', :respondent => 'Respondent'}.each do |k,v|
      name = doc.css("meta[name='#{v}']").first['content']
      ret[k] = name unless name.empty?
    end

    lower_court_node = doc.css('td').select{|x|x.text =~ /Lower Ct/}.first
    if lower_court_node
      ret[:lower_court] = lower_court_node.next.text
    end

    case_nos_node = doc.css('td').select{|x|x.text =~ /Case No/}.first
    if case_nos_node
      ret[:case_nos] = case_nos_node.next.text.gsub(/(,|\(|\))/, '').split.uniq
    end

    linked_case_node = doc.css('td').select{|x| x.text =~ /^Linked with/}.first
    if linked_case_node
      ret[:linked_cases] = linked_case_node.text.sub(/^linked with:?/i,'').sub(',', ' ').split.uniq
    end

    ret
  end

  def parse_parties doc, ret
    parties = doc.css('tr').select{|x|x.text =~ /~Name/}.first.parent.children.
      select{|c| t = c.text.strip; t !~ /^~/ && !t.empty?}
    group = nil
    partyset = []
    party_names = []
    subret = []

    parties.each do |party|
      if party.search('b').empty?
        unless party.children.count == 1  # i.e. "Party name: foo"
          partyset << party
          next
        end
      else
        group = party.content
        group.sub!(/Attorneys? for /, '')
        group.sub!(/:/, '')
        group.strip!
        next
      end

      pr_ret = {}
      pr_ret[:name] = party.content.sub('Party name: ', '').strip
      if pr_ret[:name].blank? and group =~ /etition/i
        pr_ret[:name] = ret[:petitioner].sub(/^in re\.? /i, '')
      end

      pr_ret[:representative] = partyset[0].child.content
      pr_ret[:counsel_of_record] = !!(partyset[1].child.content =~ /Counsel of Record/i)
      address = partyset.map{|x| x.children[1].content.strip rescue ''}.join("\n").strip
      pr_ret[:address] = address unless address.empty?
      phone = partyset.map{|x| x.children[2].content.strip rescue ''}.join("\n").strip
      pr_ret[:phone] = phone unless phone.empty?
      pr_ret[:group] = group
      partyset = []
      subret << pr_ret
    end
    subret
  end

  def parse_proceedings doc, ret
    subret = []
    proceedings_node = doc.css('tr').select{|x|x.text =~ /~Proceedings/}.first
    return nil unless proceedings_node # It happens sometimes, e.g. 08A370

    proceedings = proceedings_node.parent.children.map{
      |c|c.text.strip}.select{|c| c !~ /^~/ && !c.empty?}
    proceedings.each do |line|
      pr_ret = {}

      pr_ret[:date] = Date.parse line.scan(/#{DATE_REGEXP}/)[0].join(' ')
      line = line.sub(/#{DATE_REGEXP}/, '')

      line.gsub!('Court of Court', 'Court of')

      line = line.gsub("\r", '').gsub("\n", ' ').
        gsub(', ', ' ').gsub('. ', ' ').gsub('  ', ' ').strip
      line = line.sub(/^(#{ret[:type]}|application|motion) \(#{ret[:id]}\)/i, '').strip

      abstain = line.scan(/(#{JUSTICE_REGEXP}) took no part [^.]+(.|$)/)[0]
      if abstain
        j = abstain[0].gsub(/Justice ?/, '')
        j.gsub!(/(the )?chief/i, chief(pr_ret[:date]))
        pr_ret[:abstained] = j.strip
        line.sub!(/(#{JUSTICE_REGEXP}) took no part [^.]+(.|$)/, '')
        line.strip!
      end

      justice = line.scan(/(#{JUSTICE_REGEXP})/)[0]
      if justice
        j = justice[0].gsub(/Justice ?/, '')
        j.gsub!(/(the )?chief/i, chief(pr_ret[:date]))
        pr_ret[:justice] = j.strip
        line.sub!(/submitted to (#{JUSTICE_REGEXP})/, '')
        line.sub!(/by (#{JUSTICE_REGEXP})/, '')
        line.strip!
      end

      percuriam = line.scan(/by the Court/i)[0]
      if percuriam
        pr_ret[:justice] = 'per curiam'
        line.sub!(/by the court/i, '')
        line.strip!
      end

      resp = line.scan(/(granted|denied)/i)[0]
      if resp
        pr_ret[:response] = resp[0]
        line.sub!(/(granted|denied)/i, '')
      end
      line.strip!

      party_names = ret[:parties].map{|x| x[:name]}

      regexps = []
      regexps += [/(#{Regexp.escape ret[:lower_court]})/] if ret[:lower_court]
      regexps += [/(#{party_names.map{|n| Regexp.escape n}.join('|')})/] unless party_names.blank?
      regexps.each do |regex|
        parties = line.scan(regex)
        if !parties.empty?
          parties.each do |party|
            pr_ret[:parties] ||= []
            pr_ret[:parties] << party
          end
          line = line.gsub(regex, 'xxx').gsub(/(to |by )?(the )?xxx(.*xxx)?/,'').
            gsub('  ',' ').strip
        end
      end

      dates = line.scan(/from #{DATE_REGEXP} to #{DATE_REGEXP}/)
      if !dates.empty?
        pr_ret[:from_date] = Date.parse dates[0][0..2].join(' ')
        pr_ret[:to_date] = Date.parse dates[0][3..5].join(' ')
        line.sub!(/from (.*) to (.*)/, '')
      end
      dates = line.scan(/until #{DATE_REGEXP}/)
      if !dates.empty?
        pr_ret[:to_date] = Date.parse dates[0].join(' ')
        line.sub!(/until #{DATE_REGEXP}/, '')
      end
      line.strip!

      days = line.scan(/ ([^ ]+) days after the entry of this order/)[0]
      if days
        n = days[0].in_numbers
        pr_ret[:effective_date] = pr_ret[:date] + n
        line.sub!(/ ([^ ]+) days after the entry of this order/, '')
        line.strip!
      end

      date = line.scan(/conference of (#{DATE_REGEXP})/i)[0]
      if date
        pr_ret[:effective_date] = Date.parse date[0]
        line.sub!(/(?<=conference) of #{DATE_REGEXP}/i, '')
      end

      if line =~ /ordered that/i
        relief = line.scan(/ordered that (.*)/i)[0][0]
        line = line.sub(/(it is )?ordered that .*/i, '').strip
        relief.sub!(/^the /, '')
      else
        relief = line
        line = nil
      end
      relief.sub!(/^(to |for |a |the )+/, '')
      relief.sub!(/ (in|.)$/, '')

      pr_ret[:event] = relief

      pr_ret[:comment] = line if line

      subret << pr_ret
    end
    subret
  end
end