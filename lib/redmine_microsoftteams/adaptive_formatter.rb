require 'nokogiri'
require 'uri'

module RedmineMicrosoftteams
  class AdaptiveFormatter
    BLOCK_TAGS = %w[p h1 h2 h3 h4 h5 h6 pre ul ol table blockquote div hr].freeze
    attr_reader :minimum_version

    def initialize(object, base_url)
      @object = object
      @base_url = base_url
    end

    def format(text, formatting = Setting.text_formatting)
      @minimum_version = '1.2'
      html = Redmine::WikiFormatting.to_html(
        formatting, text.to_s.gsub(/\r\n?/, "\n"), :object => @object
      )
      fragment = Nokogiri::HTML.fragment(html)
      fragment.css('a.wiki-anchor').remove
      blocks(fragment.children)
    end

    private

    def blocks(nodes)
      result = []
      pending = []
      flush = lambda do
        pending.shift while pending.first&.text? && pending.first.text.strip.empty?
        pending.pop while pending.last&.text? && pending.last.text.strip.empty?
        runs = pending.flat_map { |node| inlines(node) }
        result << rich_text(runs) if runs.any? { |run| !run[:text].strip.empty? }
        pending.clear
      end

      nodes.each do |node|
        next if %w[script style].include?(node.name) || node.comment?
        unless BLOCK_TAGS.include?(node.name)
          pending << node
          next
        end

        flush.call
        case node.name
        when /\Ah[1-6]\z/
          size = {'h1' => 'ExtraLarge', 'h2' => 'Large'}.fetch(node.name, 'Medium')
          runs = inlines(node, :weight => 'Bolder', :size => size)
          result << rich_text(runs).merge(:spacing => 'Large') if runs.any?
        when 'p', 'div'
          result.concat(blocks(node.children))
        when 'pre'
          lines = node.text.sub(/\n\z/, '').split("\n", -1)
          lines = [''] if lines.empty?
          items = lines.map do |line|
            line = line.gsub("\t", '    ').sub(/\A +/) { |spaces| "\u00a0" * spaces.length }
            rich_text([{:type => 'TextRun', :text => line.empty? ? "\u00a0" : line,
                        :fontType => 'Monospace', :size => 'Small'}], :spacing => 'None')
          end
          result << {:type => 'Container', :style => 'emphasis', :spacing => 'Medium', :items => items}
        when 'blockquote'
          text = quote_markdown(node).strip
          result << {:type => 'TextBlock', :text => text, :wrap => true, :spacing => 'Medium'} unless text.empty?
        when 'ul', 'ol'
          start = node['start'].to_i
          start = 1 if start < 1
          node.xpath('./li').each_with_index do |item, index|
            marker = node.name == 'ol' ? "#{start + index}." : '•'
            items = blocks(item.children)
            next if items.empty?
            result << {
              :type => 'ColumnSet', :spacing => 'Default',
              :columns => [
                {:type => 'Column', :width => 'auto', :items => [rich_text([{:type => 'TextRun', :text => marker}])]},
                {:type => 'Column', :width => 'stretch', :items => items}
              ]
            }
          end
        when 'table'
          rows = node.xpath('./thead/tr|./tbody/tr|./tr|./tfoot/tr')
          cells = rows.map do |row|
            row.xpath('./th|./td').map do |cell|
              style = cell.name == 'th' ? {:weight => 'Bolder'} : {}
              cell.children.flat_map { |child| inlines(child, style) }
            end
          end
          column_count = cells.map(&:length).max.to_i
          next if column_count.zero?

          widths = Array.new(column_count, 1)
          cells.each do |row|
            row.each_with_index do |runs, column_index|
              length = runs.sum { |run| run[:text].length }
              widths[column_index] = [widths[column_index], length].max
            end
          end
          table_rows = cells.map do |row|
            table_cells = column_count.times.map do |column_index|
              runs = row[column_index] || []
              runs = [{:type => 'TextRun', :text => "\u00a0"}] if runs.empty?
              {:type => 'TableCell', :items => [rich_text(runs)]}
            end
            {:type => 'TableRow', :cells => table_cells}
          end
          result << {:type => 'Table', :spacing => 'Large', :showGridLines => true, :gridStyle => 'default',
                     :firstRowAsHeaders => rows.first.xpath('./th').length == column_count,
                     :columns => widths.map { |width| {:width => Math.log2(width + 1).round} }, :rows => table_rows}
          @minimum_version = '1.5'
        when 'hr'
          result << rich_text([{:type => 'TextRun', :text => '—'}], :separator => true)
        end
      end
      flush.call
      result
    end

    def rich_text(runs, options = {})
      {:type => 'RichTextBlock', :inlines => runs, :spacing => 'Medium'}.merge(options)
    end

    def quote_markdown(node)
      if node.text?
        return '' if node.text.strip.empty? && %w[blockquote ul ol table thead tbody tfoot tr].include?(node.parent.name)
        return node.text
      end
      return '' if node.comment? || %w[script style].include?(node.name)

      text = node.children.map { |child| quote_markdown(child) }.join
      case node.name
      when 'blockquote'
        text.strip.lines.map { |line| "> #{line}" }.join + "\n\n"
      when 'p', 'div', 'ul', 'ol'
        "#{text.strip}\n\n"
      when /\Ah[1-6]\z/
        "#{'#' * node.name[1].to_i} #{text.strip}\n\n"
      when 'br'
        "\n"
      when 'strong', 'b'
        "**#{text}**"
      when 'em', 'i'
        "*#{text}*"
      when 'del', 's'
        "~~#{text}~~"
      when 'pre'
        fence = '`' * [(node.text.scan(/`+/).map(&:length).max || 0) + 1, 3].max
        "#{fence}\n#{node.text.sub(/\n\z/, '')}\n#{fence}\n\n"
      when 'code'
        delimiter = '`' * ((text.scan(/`+/).map(&:length).max || 0) + 1)
        padding = text.start_with?('`') || text.end_with?('`') ? ' ' : ''
        "#{delimiter}#{padding}#{text}#{padding}#{delimiter}"
      when 'li'
        start = [node.parent['start'].to_i, 1].max
        marker = node.parent.name == 'ol' ? "#{start + node.xpath('preceding-sibling::li').length}." : '-'
        "#{marker} #{text.strip.gsub("\n", "\n" + ' ' * (marker.length + 1))}\n"
      when 'table'
        "#{text.strip}\n\n"
      when 'tr'
        cells = node.xpath('./th|./td')
        row = '| ' + cells.map { |cell| quote_markdown(cell).strip }.join(' | ') + " |\n"
        row += '| ' + Array.new(cells.length, '---').join(' | ') + " |\n" if cells.all? { |cell| cell.name == 'th' }
        row
      when 'input'
        inlines(node).map { |run| run[:text] }.join
      when 'hr'
        "\n---\n"
      when 'a', 'img'
        run = inlines(node).first
        url = run && run.dig(:selectAction, :url)
        label = node.name == 'img' ? run[:text] : text
        url ? "[#{label}](#{url})" : label
      else
        text
      end
    end

    def inlines(node, style = {})
      return [] if node.comment? || %w[script style].include?(node.name)
      if node.text?
        text = node.text
        text = text.sub(/\A\n/, '') if node.previous_sibling&.name == 'br'
        return text.empty? ? [] : [{:type => 'TextRun', :text => text}.merge(style)]
      end
      return [{:type => 'TextRun', :text => "\n"}.merge(style)] if node.name == 'br'
      if node.name == 'input' && node['type'] == 'checkbox'
        return [{:type => 'TextRun', :text => node.key?('checked') ? '☑ ' : '☐ '}.merge(style)]
      end

      case node.name
      when 'strong', 'b'
        style = style.merge(:weight => 'Bolder')
      when 'em', 'i'
        style = style.merge(:italic => true)
      when 'del', 's'
        style = style.merge(:strikethrough => true)
      when 'code'
        style = style.merge(:fontType => 'Monospace')
      when 'a'
        url = absolute_url(node['href'])
        style = style.merge(:selectAction => {:type => 'Action.OpenUrl', :url => url}) if url
      when 'img'
        source = node['src']
        if @object.respond_to?(:attachments)
          filename = URI::DEFAULT_PARSER.unescape(source.to_s)
          attachment = Attachment.latest_attach(@object.attachments, filename)
          if attachment
            object_path = Rails.application.routes.url_for(@object.event_url(:only_path => true, :script_name => ''))
            base_path = URI.parse(@base_url).path
            prefix = base_path.end_with?(object_path) ? base_path[0, base_path.length - object_path.length] : ''
            source = Rails.application.routes.url_for(attachment.event_url(:only_path => true, :script_name => prefix))
          end
        end
        url = absolute_url(source)
        run = {:type => 'TextRun', :text => node['alt'].presence || 'Image'}.merge(style)
        run[:selectAction] = {:type => 'Action.OpenUrl', :url => url} if url
        return [run]
      end

      node.children.flat_map { |child| inlines(child, style) }
    end

    def absolute_url(value)
      return nil if value.to_s.empty?
      uri = URI.join(@base_url, value)
      uri.to_s if %w[http https mailto].include?(uri.scheme)
    rescue URI::InvalidURIError
      nil
    end
  end
end
