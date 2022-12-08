require 'redmine'

require File.expand_path('../lib/redmine_microsoftteams/listener', __FILE__)

Redmine::Plugin.register :redmine_microsoftteams do
  name 'Redmine Microsoft Teams'
  author 'wellbia'
  url 'https://github.com/wellbia/redmine_microsoftteams'
  author_url 'https://github.com/wellbia'
  description 'Microsoft Teams chat integration'
  version '0.1'

  requires_redmine :version_or_higher => '0.8.0'

  settings \
    :default => {
      'display_watchers' => 'no'
    },
    :partial => 'settings/microsoftteams_settings'
end

if Rails.version > '6.0' && Rails.autoloaders.zeitwerk_enabled?
  Rails.application.config.after_initialize do
    unless Issue.included_modules.include? RedmineMicrosoftteams::IssuePatch
      Issue.send(:include, RedmineMicrosoftteams::IssuePatch)
    end
  end
else
  ((Rails.version > "5")? ActiveSupport::Reloader : ActionDispatch::Callbacks).to_prepare do
    require_dependency 'issue'
    unless Issue.included_modules.include? RedmineMicrosoftteams::IssuePatch
      Issue.send(:include, RedmineMicrosoftteams::IssuePatch)
    end
  end
end
