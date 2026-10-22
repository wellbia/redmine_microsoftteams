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

Run plugin migrations to enable the Microsoft Teams project module for existing projects and add it to Redmine's default project modules:
```
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

## Customized Routing

You can also route messages to different channels on a per-project basis. To do this, create a project custom field (Administration > Custom fields > Project) named `Teams URL`. If no custom channel is defined for a project, the parent project will be checked(or the default will be used). To prevent all notifications from being sent for a project, set the custom channel to `-`.

Microsoft Teams notifications can be enabled or disabled per project from Project settings > Modules. The `Microsoft Teams webhook` module is enabled by default; uncheck it to disable all Teams notifications for that project.

## Teams body formatting

Adaptive Cards use Redmine's configured Markdown or Textile renderer, then map
headings, paragraphs, lists, tables, quotations, and code to card elements.
Quotations retain their `>` markers in a Teams text block, matching the previous
handling; other elements use native card formatting.
Paragraphs, headings, and the start of each table have extra spacing. Tables
use the native Adaptive Card `Table` with grid lines and one shared column definition
for all rows. Column weights are estimated once per table from the longest cell
text in each column, using logarithmic scaling rounded to integer weights for
Teams Workflow compatibility. Missing cells are padded to keep rows aligned.
Cards containing native tables require Adaptive Cards 1.5 support in both the receiving
Workflow and Teams client; other cards
use 1.2. A table card includes its issue summary as fallback text for clients
that cannot display it. Task lists preserve their checked state as read-only text.
Code blocks use a shaded monospace area with preserved indentation. Inline code
uses monospace text runs without boxes, with surrounding emphasis and links
preserved. Text uses native rich text styles. Relative links point back to Redmine.
Images are represented by links because Redmine attachments may require login.
Redmine macros and automatic references such as `#123` and `[[WikiPage]]` remain
as written. They do not expand other issues or Wiki content into notifications;
use explicit Markdown or Textile links for clickable references.

Issue titles link to Redmine. Adaptive issue messages include a plain-text
`summary` with the author, activity, and issue for receiving Workflows.
Adaptive messages use a conservative 24,000-byte
budget measured in both UTF-8 and UTF-16, leaving room for the Teams connector's
message overhead. Large cards show a partial preview with a clickable notice;
use the notice or title link to read the full content. Legacy connector cards
retain their existing formatting.

Adaptive update cards show title changes in two columns of plain text with the new title
after an arrow, and link the issue number above them. Single-value issue fields and custom
fields show previous → new values; attachments, relations, and multi-value
fields keep their existing display. When
the description changes, the card renders the new description followed by any
comment. A **View changes** link opens Redmine's diff for that specific journal
entry instead of displaying a diff in the notification.
Changeset notices use native text and links without a Markdown formatter.
Wiki comment text remains literal, while the Wiki page title stays clickable.
