class EnableMicrosoftteamsProjectModule < (ActiveRecord::Migration.respond_to?(:[]) ? ActiveRecord::Migration[4.2] : ActiveRecord::Migration)
  def up
    module_name = 'microsoftteams'

    Project.all.each do |project|
      unless EnabledModule.exists?(:project_id => project.id, :name => module_name)
        EnabledModule.create!(:project_id => project.id, :name => module_name)
      end
    end

    default_modules = Array(Setting.default_projects_modules)
    Setting.default_projects_modules = (default_modules | [module_name])
  end

  def down
    module_name = 'microsoftteams'

    EnabledModule.where(:name => module_name).delete_all
    Setting.default_projects_modules = Array(Setting.default_projects_modules) - [module_name]
  end
end
