require 'httpclient'
require 'json'

module RedmineMicrosoftteams
class Listener < Redmine::Hook::Listener
  def redmine_microsoftteams_issues_new_after_save(context={})
    issue = context[:issue]

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

    sections = escape_description issue.description if issue.description
    facts[I18n.t("field_watcher")] = escape(issue.watcher_users.join(', ')) if Setting.plugin_redmine_microsoftteams['display_watchers'] == 'yes'

    speak title, text, sections, facts, url
  end

  def redmine_microsoftteams_issues_edit_after_save(context={})
    return unless Setting.plugin_redmine_microsoftteams['post_updates'] == '1'

    issue = context[:issue]
    journal = context[:journal]
    return if issue.is_private? || journal.private_notes?

    url = url_for_project issue.project
    return unless url

    title = "#{escape issue.project}"
    text = "#{escape journal.user.to_s} #{l(:issue_updated)} [#{escape issue}](#{object_url issue}) #{mentions journal.notes}"

    sections = escape_description journal.notes if journal.notes
    facts = get_facts(journal)

    speak title, text, sections, facts, url
  end

  def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context={})
    issue = context[:issue]
    journal = issue.current_journal
    changeset = context[:changeset]

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

    facts_title= ll(Setting.default_language, :text_status_changed_by_changeset, "[#{escape changeset.comments}](#{revision_url})")
    facts = get_facts(journal)

    sections = {:text => facts_title}
    speak title, text, sections, facts, url
  end

  def controller_wiki_edit_after_save(context = { })
    return unless Setting.plugin_redmine_microsoftteams['post_wiki_updates'] == '1'

    project = context[:project]
    page = context[:page]

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

    speak title, text, sections, facts, url
  end

  def speak(title, text, sections=nil, facts=nil, url=nil)
    url = Setting.plugin_redmine_microsoftteams['teams_url'] if not url

    if url.downcase.include?("webhook")
      sections = [] if not sections

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
      fact_set = []
      if facts
        facts.each do |name, value|
          fact_set << { "title": name, "value": value }
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

      adaptive_card[:body] << { "type": "TextBlock", "text": title, "weight": "bolder", "size": "medium" } if title
      adaptive_card[:body] << { "type": "TextBlock", "text": text, "wrap": true } if text
      adaptive_card[:body] << { "type": "TextBlock", "text": hash_to_string(sections), "wrap": true} if sections
      adaptive_card[:body].concat(adaptive_card_sections)

      msg = {}
      msg[:type] = "message"
      msg[:attachments] = [
        {
          "contentType": "application/vnd.microsoft.card.adaptive",
          "content": adaptive_card
        }
      ]
    end

    begin
      client = HTTPClient.new
      client.ssl_config.cert_store.set_default_paths
      client.ssl_config.ssl_version = :auto
      client.post_async url, msg.to_json, {'Content-Type': 'application/json'}
    rescue Exception => e
      Rails.logger.warn("cannot connect to #{url}")
      Rails.logger.warn(e)
    end
  end

private
  def get_facts(journal)
    facts = {}
    journal.details.map { |d| facts.merge!(detail_to_field d) }
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
      "\r\n" => "<br/>",
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

  def detail_to_field(detail)
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
      user = User.find(detail.value) rescue nil
      value = escape user.to_s
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

    value = "-" if value.empty?
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

  def hash_to_string(sections)
    return sections.map { |hash| hash[:text] }.join
  end
end
end
