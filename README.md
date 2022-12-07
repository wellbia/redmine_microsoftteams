# Microsoft chat plugin for Redmine

This plugin posts updates to issues in your Redmine installation to a Microsoft Teams channel.

This code is based on the [redmine-slack](https://github.com/sciyoshi/redmine-slack) plugin.

## Installation

From your Redmine plugins directory, clone this repository as `redmine_microsoftteams`
```
git clone https://github.com/wellbia/redmine_microsoftteams.git redmine_microsoftteams
```

You will also need the `httpclient` dependency, which can be installed by running
```
bundle install
```
from the plugin directory.

Restart Redmine, and you should see the plugin show up in the Plugins page. Under the configuration options, set the Teams URL to the url for Microsoft Teams Incoming Webhook in your Microsoft Teams channel.

## Customized Routing

You can also route messages to different channels on a per-project basis. To do this, create a project custom field (Administration > Custom fields > Project) named `Teams URL`. If no custom channel is defined for a project, the parent project will be checked(or the default will be used). To prevent all notifications from being sent for a project, set the custom channel to `-`.

## Difference with redmine-slack Plugin

In this plugin, somethings is not beautiful to see(ex. newline, missing html entity in codeblock). We will fix it if find a better way.