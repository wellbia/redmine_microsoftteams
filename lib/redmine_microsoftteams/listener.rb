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
		text = "#{escape issue.author} created [#{escape issue}](#{object_url issue}) #{mentions issue.description}"

		facts = {
			I18n.t("field_status") => escape(issue.status.to_s),
			I18n.t("field_priority") => escape(issue.priority.to_s),
			I18n.t("field_assigned_to") => escape(issue.assigned_to.to_s)
		}

		facts_title = escape issue.description if issue.description
		facts[I18n.t("field_watcher")] = escape(issue.watcher_users.join(', ')) if Setting.plugin_redmine_microsoftteams['display_watchers'] == 'yes'

		speak title, text, facts_title, facts, url
	end

	def redmine_microsoftteams_issues_edit_after_save(context={})
		return unless Setting.plugin_redmine_microsoftteams['post_updates'] == '1'

		issue = context[:issue]
		journal = context[:journal]
		return if issue.is_private? || journal.private_notes?

		url = url_for_project issue.project
		return unless url

		title = "#{escape issue.project}"
		text = "#{escape journal.user.to_s} updated [#{escape issue}](#{object_url issue}) #{mentions journal.notes}"

		facts_title = escape journal.notes if journal.notes
		facts = get_facts(journal)

		speak title, text, facts_title, facts, url
	end

	def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context={})
		issue = context[:issue]
		journal = issue.current_journal
		changeset = context[:changeset]

		url = url_for_project issue.project

		return unless url and issue.save
		return if issue.is_private?

		title = "#{escape issue.project}"
		text = "#{escape journal.user.to_s} updated [#{escape issue}](#{object_url issue})"

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

		speak title, text, facts_title, facts, url
	end

	def controller_wiki_edit_after_save(context = { })
		return unless Setting.plugin_redmine_microsoftteams['post_wiki_updates'] == '1'

		project = context[:project]
		page = context[:page]

		user = page.content.author
		page_url = "[#{page.title}](#{object_url page})"
		comment = "#{page_url} updated by *#{user}*"

		url = url_for_project project

		title = "#{escape project}"

		if not page.content.comments.empty?
			text = "#{comment}\n\n#{escape page.content.comments}"
		end

		facts_title = nil
		facts = nil

		speak title, text, facts_title, facts, url
	end

	def speak(title, text, facts_title=nil, facts=nil, url=nil)
		url = Setting.plugin_redmine_microsoftteams['teams_url'] if not url

		section = {}
		section[:title] = facts_title if facts_title
		section[:facts] = []
		facts.each { |name, value| section[:facts] << {:name => name, :value => value}}

		msg = {}
		msg[:title] = title if title
		msg[:text] = text if text
		msg[:sections] = [] << section if section

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

	def escape(msg)
		subs = {
			"<pre>" => "```",
			"</pre>" => "```",
			"&" => "&amp;",
			"<" => "&lt;",
			">" => "&gt;",
			"\r\n" => "<br/>",
			"[" => "&#91;",
			"]" => "&#93;",
			"\\" => "&#92;"
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
end
end
