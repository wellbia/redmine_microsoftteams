require 'httpclient'
require 'json'
require 'cgi'
require_relative 'adaptive_formatter'

module RedmineMicrosoftteams
class Listener < Redmine::Hook::Listener
  def redmine_microsoftteams_issues_new_after_save(context={})
    issue = context[:issue]

    return unless microsoftteams_enabled_for_project?(issue.project)

    url = url_for_project issue.project

    return unless url
    return if issue.is_private?

    title = "#{escape issue.project}"
    text = "#{escape issue.author} #{l(:issue_created)} [#{escape issue}](#{object_url issue}) #{mentions issue.description}"

    facts = {
      I18n.t("field_status") => escape(issue.status.to_s),
      I18n.t("field_priority") => escape(issue.priority.to_s),
      I18n.t("field_assigned_to") => escape(issue.assigned_to.to_s)
    }

    sections = issue.description if issue.description
    facts[I18n.t("field_watcher")] = escape(issue.watcher_users.join(', ')) if Setting.plugin_redmine_microsoftteams['display_watchers'] == 'yes'

    speak title, text, sections, facts, url, issue
  end

  def redmine_microsoftteams_issues_edit_after_save(context={})
    return unless Setting.plugin_redmine_microsoftteams['post_updates'] == '1'

    issue = context[:issue]
    journal = context[:journal]
    return if issue.is_private? || journal.private_notes?
    return unless microsoftteams_enabled_for_project?(issue.project)

    url = url_for_project issue.project
    return unless url

    title = "#{escape issue.project}"
    text = "#{escape journal.user.to_s} #{l(:issue_updated)} [#{escape issue}](#{object_url issue}) #{mentions journal.notes}"

    sections = journal.notes if journal.notes
    facts = get_facts(journal, !url.downcase.include?("webhook"))

    speak title, text, sections, facts, url, issue, journal
  end

  def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context={})
    issue = context[:issue]
    journal = issue.current_journal
    changeset = context[:changeset]

    return unless microsoftteams_enabled_for_project?(issue.project)

    url = url_for_project issue.project

    return unless url and issue.save
    return if issue.is_private?

    title = "#{escape issue.project}"
    text = "#{escape journal.user.to_s} #{l(:issue_updated)} [#{escape issue}](#{object_url issue})"

    repository = changeset.repository

    if Setting.host_name.to_s =~ /\A(https?\:\/\/)?(.+?)(\:(\d+))?(\/.+)?\z/i
      host, port, prefix = $2, $4, $5
      revision_url = Rails.application.routes.url_for(
        :controller => 'repositories',
        :action => 'revision',
        :id => repository.project,
        :repository_id => repository.identifier_param,
        :rev => changeset.revision,
        :host => host,
        :protocol => Setting.protocol,
        :port => port,
        :script_name => prefix
      )
    else
      revision_url = Rails.application.routes.url_for(
        :controller => 'repositories',
        :action => 'revision',
        :id => repository.project,
        :repository_id => repository.identifier_param,
        :rev => changeset.revision,
        :host => Setting.host_name,
        :protocol => Setting.protocol
      )
    end

    revision_link = "[#{escape changeset.comments}](#{revision_url})"
    facts_title = ll(Setting.default_language, :text_status_changed_by_changeset, revision_link)
    facts = get_facts(journal, !url.downcase.include?("webhook"))

    before, _, after = facts_title.partition(revision_link)
    sections = {:text => facts_title, :inlines => [
      {:type => 'TextRun', :text => before},
      {:type => 'TextRun', :text => changeset.comments.to_s,
       :selectAction => {:type => 'Action.OpenUrl', :url => revision_url}},
      {:type => 'TextRun', :text => after}
    ]}
    speak title, text, sections, facts, url, issue, journal
  end

  def controller_wiki_edit_after_save(context = { })
    return unless Setting.plugin_redmine_microsoftteams['post_wiki_updates'] == '1'

    project = context[:project]
    page = context[:page]
    return unless microsoftteams_enabled_for_project?(project)

    user = page.content.author
    page_url = "[#{page.title}](#{object_url page})"
    comment = "#{page_url} #{l(:wiki_updated_by)} *#{user}*"

    url = url_for_project project

    title = "#{escape project}"

    if not page.content.comments.empty?
      text = "#{comment}\n\n#{escape page.content.comments}"
    end

    sections = nil
    facts = nil

    speak title, text, sections, facts, url, page
  end

  def speak(title, text, sections=nil, facts=nil, url=nil, object=nil, journal=nil)
    url = Setting.plugin_redmine_microsoftteams['teams_url'] if not url

    if url.downcase.include?("webhook")
      if sections
        sections = sections[:text] if sections.is_a?(Hash)
        sections = escape_description limit_string_length sections
      else
        sections = []
      end

      section = {}
      section[:facts] = []
      facts.each { |name, value| section[:facts] << {:name => name, :value => value}}
      if section[:facts].length != 0
        sections << section
      end

      msg = {}
      msg[:title] = title if title
      msg[:text] = text if text
      msg[:sections] = sections
    else
      # Create the Adaptive Card structure
      subject_change = journal.details.detect { |detail| detail.property == 'attr' && detail.prop_key == 'subject' } if journal && object.is_a?(Issue)
      fact_set = []
      if facts
        facts.each do |name, value|
          fact_set << { "title": name, "value": CGI.unescapeHTML(value.to_s) }
        end
      end

      adaptive_card_sections = []
      adaptive_card_sections << {
        "type": "FactSet",
        "facts": fact_set
      } if fact_set.length != 0

      adaptive_card = {
        "type": "AdaptiveCard",
        "version": "1.2",
        "body": []
      }

      if title
        adaptive_card[:body] << {:type => 'RichTextBlock', :inlines => [
          {:type => 'TextRun', :text => CGI.unescapeHTML(title), :weight => 'Bolder', :size => 'Medium'}
        ]}
      end
      if object.is_a?(Issue)
        author = journal ? journal.user : object.author
        activity = journal ? l(:issue_updated) : l(:issue_created)
        adaptive_card[:body] << {:type => 'RichTextBlock', :inlines => [
          {:type => 'TextRun', :text => "#{author} #{activity} "},
          {:type => 'TextRun', :text => subject_change ? "#{object.tracker} ##{object.id}" : object.to_s, :weight => 'Bolder',
           :selectAction => {:type => 'Action.OpenUrl', :url => object_url(object)}}
        ]}
      elsif text && object.is_a?(WikiPage)
        adaptive_card[:body] << {:type => 'RichTextBlock', :inlines => [
          {:type => 'TextRun', :text => object.title,
           :selectAction => {:type => 'Action.OpenUrl', :url => object_url(object)}},
          {:type => 'TextRun', :text => " #{l(:wiki_updated_by)} "},
          {:type => 'TextRun', :text => object.content.author.to_s, :italic => true}
        ]}
        adaptive_card[:body] << {:type => 'RichTextBlock', :inlines => [
          {:type => 'TextRun', :text => object.content.comments.to_s}
        ]}
      elsif text
        adaptive_card[:body] << { "type": "TextBlock", "text": CGI.unescapeHTML(text), "wrap": true }
      end
      if subject_change
        old_title = subject_change.old_value.presence || I18n.t(:label_none)
        new_title = subject_change.value.presence || I18n.t(:label_none)
        adaptive_card[:body] << {:type => 'ColumnSet', :columns => [
          {:type => 'Column', :width => 'auto', :items => [
            {:type => 'RichTextBlock', :inlines => [
              {:type => 'TextRun', :text => I18n.t(:field_subject), :weight => 'Bolder'}
            ]}
          ]},
          {:type => 'Column', :width => 'stretch', :items => [
            {:type => 'RichTextBlock', :inlines => [
              {:type => 'TextRun', :text => "#{old_title}\n→ #{new_title}"}
            ]}
          ]}
        ]}
      end
      adaptive_card[:body].concat(adaptive_card_sections)
      description = []
      truncated = false
      base_url = object ? object_url(object) : "#{Setting.protocol}://#{Setting.host_name}/"
      sources = []
      changed_description = journal.details.detect { |detail| detail.property == 'attr' && detail.prop_key == 'description' } if journal && !sections.is_a?(Hash)
      if changed_description
        inlines = [{:type => 'TextRun', :text => l(:field_description), :weight => 'Bolder'}]
        if journal.persisted? && changed_description.persisted?
          object_path = Rails.application.routes.url_for(object.event_url(:only_path => true, :script_name => ''))
          base_path = URI.parse(base_url).path
          prefix = base_path.end_with?(object_path) ? base_path[0, base_path.length - object_path.length] : ''
          path = Rails.application.routes.url_helpers.diff_journal_path(journal.id, :detail_id => changed_description.id, :script_name => prefix)
          inlines << {:type => 'TextRun', :text => "  #{l(:teams_view_changes)}",
                      :selectAction => {:type => 'Action.OpenUrl', :url => URI.join(base_url, path).to_s}}
        end
        adaptive_card[:body] << {:type => 'RichTextBlock', :inlines => inlines}
        sources << {:text => changed_description.value.presence || '—', :formatting => Setting.text_formatting}
      end
      if sections.is_a?(Hash)
        inlines = sections[:inlines].reject { |run| run[:text].to_s.empty? }
        description << {:type => 'RichTextBlock', :inlines => inlines} if inlines.any?
      elsif sections.present?
        sources << {:text => sections,
                    :formatting => Setting.text_formatting,
                    :title => changed_description ? l(:field_notes) : nil}
      end
      remaining = 14000
      notes_heading = nil
      sources.each do |part|
        source = part[:text].to_s
        truncated ||= source.length > remaining
        source = source[0, remaining]
        remaining -= source.length
        next if source.empty?

        if part[:title]
          notes_heading = {:type => 'RichTextBlock', :inlines => [
            {:type => 'TextRun', :text => part[:title], :weight => 'Bolder'}
          ]}
          description << notes_heading
        end
        begin
          formatter = AdaptiveFormatter.new(object, base_url)
          description.concat(formatter.format(source, part[:formatting]))
          adaptive_card[:version] = '1.5' if formatter.minimum_version == '1.5'
        rescue StandardError => e
          Rails.logger.warn("cannot format Microsoft Teams content (#{e.class})")
          description << {:type => 'RichTextBlock', :inlines => [{:type => 'TextRun', :text => source}]}
        end
        description.pop if notes_heading && description.last.equal?(notes_heading)
      end
      header = adaptive_card[:body].dup
      adaptive_card[:body].concat(description)
      truncation_notice = {:type => 'RichTextBlock', :inlines => [
        {:type => 'TextRun', :text => l(:teams_body_truncated), :isSubtle => true,
         :selectAction => {:type => 'Action.OpenUrl', :url => base_url}}
      ]}
      adaptive_card[:body] << truncation_notice if truncated
      adaptive_card[:msteams] = { "width": "Full" }

      msg = {}
      msg[:type] = "message"
      msg[:summary] = object.is_a?(Issue) ? "#{author} #{activity} #{object}" : CGI.unescapeHTML(title.to_s)
      if adaptive_card[:version] == '1.5'
        adaptive_card[:fallbackText] = msg[:summary]
      end
      msg[:attachments] = [
        {
          "contentType": "application/vnd.microsoft.card.adaptive",
          "content": adaptive_card
        }
      ]
      message_size = lambda do
        json = msg.to_json
        [json.bytesize, json.encode(Encoding::UTF_16LE).bytesize].max
      end
      while message_size.call > 24000 && (description.any? || fact_set.any?)
        if description.any?
          description.pop
          description.pop if notes_heading && description.last.equal?(notes_heading)
        else
          fact_set.pop
          header -= adaptive_card_sections if fact_set.empty?
        end
        adaptive_card[:body] = header + description + [truncation_notice]
      end
    end

    begin
      client = HTTPClient.new
      client.ssl_config.cert_store.set_default_paths
      client.ssl_config.ssl_version = :auto
      client.post_async url, msg.to_json, {'Content-Type': 'application/json'}
    rescue Exception => e
      Rails.logger.warn("cannot connect to Microsoft Teams (#{e.class})")
    end
  end

private
  def get_facts(journal, include_changes = false)
    facts = {}
    empty_value = include_changes ? I18n.t(:label_none) : "-"
    journal.details.each do |detail|
      next if include_changes && detail.property == 'attr' && detail.prop_key == 'description'
      next if include_changes && detail.property == 'attr' && detail.prop_key == 'subject'
      field = detail_to_field(detail, empty_value)
      single_value = detail.property == 'attr' && detail.prop_key != 'child_id'
      if detail.property == 'cf' && detail.custom_field
        format = detail.custom_field.format.class
        single_value = !detail.custom_field.multiple? && !format.change_no_details && !format.change_as_diff
      end
      if include_changes && single_value
        if detail.prop_key == 'assigned_to_id'
          old_value, new_value = [detail.old_value, detail.value].map do |id|
            escape(Principal.find_by_id(id).to_s).presence || I18n.t(:label_none)
          end
        else
          previous = detail.dup
          previous.value = detail.old_value
          old_value = detail_to_field(previous, empty_value).values.first
          new_value = field.values.first
        end
        field = field.transform_values { "#{old_value} → #{new_value}" }
      end
      facts.merge!(field)
    end
    return facts
  end


  def get_entry(x)
    return {:text => escape(x) }
  end

  def find_end_of_tag(msg, spos, btag, etag)
    cpos = spos
    depth = 0
    pre_tag_end = nil
    # find outmost end of tag
    while cpos < msg.length

      if msg[cpos..cpos+btag.length-1] == btag
        depth += 1
        cpos += btag.length
      elsif msg[cpos..cpos+etag.length-1] == etag
        depth -= 1
          
        if depth == 0
          return cpos + etag.length
        end

        cpos += etag.length
      else        
        cpos += 1
      end
    end
  end

  def escape_description(msg)
    cpos = 0
    msgl = []
  
    while cpos < msg.length
      npos = msg.index('<pre>', cpos)
      if npos == nil
        msgl.push(get_entry(msg[cpos..-1]))
        break
      end
    
      if cpos != npos
        msgl.push(get_entry(msg[cpos...npos]))
      end
      cpos = npos
    
      npos = find_end_of_tag(msg, cpos, '<pre>', '</pre>')
      if npos == nil
        msgl.push(get_entry(msg[cpos..-1]))
        break
      end
    
      msgl.push({:text => "```\r\n" + msg[cpos+5...npos-6]})
      cpos = npos
    end
  
    return msgl
  end

  def escape(msg)
    subs = {
      "&" => "&amp;",
      "<" => "&lt;",
      ">" => "&gt;",
      "\r" => "\n",
      "[" => "&#91;",
      "]" => "&#93;",
      "\\" => "&#92;",
      "~" => "&#126;",
      "{" => "&#123;",
      "}" => "&#125;",
      ":" => "&#58;"
    }

    re = Regexp.union(subs.keys)
    msg.to_s.gsub(re, subs)
  end

  def object_url(obj)
    if Setting.host_name.to_s =~ /\A(https?\:\/\/)?(.+?)(\:(\d+))?(\/.+)?\z/i
      host, port, prefix = $2, $4, $5
      Rails.application.routes.url_for(obj.event_url({
        :host => host,
        :protocol => Setting.protocol,
        :port => port,
        :script_name => prefix
      }))
    else
      Rails.application.routes.url_for(obj.event_url({
        :host => Setting.host_name,
        :protocol => Setting.protocol
      }))
    end
  end

  def url_for_project(proj)
    return nil if proj.blank?

    cf = ProjectCustomField.find_by_name("Teams URL")

    return [
      (proj.custom_value_for(cf).value rescue nil),
      (url_for_project proj.parent),
      Setting.plugin_redmine_microsoftteams['teams_url'],
    ].find{|v| v.present?}
  end

  def microsoftteams_enabled_for_project?(project)
    return false if project.blank?
    return true unless project.respond_to?(:module_enabled?)

    project.module_enabled?(:microsoftteams)
  end

  def detail_to_field(detail, empty_value)
    case detail.property
    when "cf"
      custom_field = detail.custom_field
      key = custom_field.name
      title = key
      value = (detail.value)? IssuesController.helpers.format_value(detail.value, custom_field) : ""
    when "attachment"
      key = "attachment"
      title = I18n.t :label_attachment
      value = escape detail.value.to_s
    else
      key = detail.prop_key.to_s.sub("_id", "")
      if key == "parent"
        title = I18n.t "field_#{key}_issue"
      else
        title = I18n.t "field_#{key}"
      end
      value = escape detail.value.to_s
    end

    case key
    when "title", "subject", "description"
    when "tracker"
      tracker = Tracker.find(detail.value) rescue nil
      value = escape tracker.to_s
    when "project"
      project = Project.find(detail.value) rescue nil
      value = escape project.to_s
    when "status"
      status = IssueStatus.find(detail.value) rescue nil
      value = escape status.to_s
    when "priority"
      priority = IssuePriority.find(detail.value) rescue nil
      value = escape priority.to_s
    when "category"
      category = IssueCategory.find(detail.value) rescue nil
      value = escape category.to_s
    when "assigned_to"
      principal = Principal.find_by_id(detail.value)
      value = escape principal.to_s
    when "fixed_version"
      version = Version.find(detail.value) rescue nil
      value = escape version.to_s
    when "attachment"
      attachment = Attachment.find(detail.prop_key) rescue nil
      value = "[#{escape attachment.filename}](#{object_url attachment})" if attachment
    when "parent"
      issue = Issue.find(detail.value) rescue nil
      value = "[#{escape issue}](#{object_url issue})" if issue
    end

    value = empty_value if value.empty?
    return { title => value }
  end

  # Don't work in MS Teams
  def mentions(text)
    return nil
    names = extract_usernames text
    names.present? ? "\nTo: " + names.join(', ') : nil
  end

  def extract_usernames(text = '')
    if text.nil?
      text = ''
    end

    # teams usernames may only contain lowercase letters, numbers,
    # dashes and underscores and must start with a letter or number.
    text.scan(/@[a-z0-9][a-z0-9_\-]*/).uniq
  end

  def limit_string_length(str)
    if str.length > 14000
      str[0..14000] + "..."
    else
      str
    end
  end
end
end
