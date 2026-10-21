# action_mailbox_graph

`action_mailbox_graph` connects Rails Action Mailbox and Action Mailer to Exchange Online through Microsoft Graph REST endpoints.
It sends rendered MIME and polls a mailbox folder for new messages, then hands the original MIME to Action Mailbox.

The gem requires Ruby 3.3 or newer and Rails 8.0 or 8.1.
These ranges were checked against the [Ruby downloads page](https://www.ruby-lang.org/en/downloads/) and the [Rails maintenance page](https://rubyonrails.org/maintenance) on 2026-10-21.

## Install from the private repository

Add a tag-pinned Git dependency to the consuming application's `Gemfile`:

```ruby
gem "action_mailbox_graph", git: "https://github.com/t27sol/action_mailbox_graph.git", tag: "v0.1.0"
```

The repository is private and this gem is not published to RubyGems.
Make sure Bundler's Git credentials can read the repository in local development and deployment.

## Rails setup

Install the gem, install Action Mailbox as described in the Rails guide, and run the database migrations:

```sh
bundle install
bin/rails action_mailbox:install
bin/rails generate action_mailbox_graph:install
bin/rails db:migrate
```

Configure one shared mailbox per environment in an initializer:

```ruby
# config/initializers/action_mailbox_graph.rb
ActionMailboxGraph.configure do |config|
  config.mailbox = ENV.fetch("EXCHANGE_SHARED_MAILBOX")
  config.identity_client_id = ENV["AZURE_MAIL_IDENTITY_CLIENT_ID"]
  config.folder = "Inbox"
  config.processed_folder = nil # Or a Graph mail folder ID to move messages after handoff.
  config.poll_batch_size = 50
  config.max_retries = 3
  config.http_open_timeout = 5
  config.http_read_timeout = 30
  config.http_write_timeout = 30
end

Rails.application.config.action_mailer.delivery_method = :microsoft_graph
```

By default, the gem uses Azure managed identity and selects the user-assigned identity configured by `identity_client_id`.
Leave the client ID empty to use the hosting service's default managed identity.
The Graph client uses the configured mailbox for every operation unless a caller explicitly supplies a different mailbox.

Action Mailbox routes the received MIME asynchronously using the application's normal `ApplicationMailbox` routing rules.
The gem prepends `X-Original-To` with the shared mailbox address so address-based routes also match blind-copied messages.
Use `config.processed_folder` only with a Graph folder ID; when it is unset, successfully handed-off messages are marked read.
Use `config.state_store` to provide a custom store that implements `delta_link`, `last_polled_at`, `save_delta_link`, `received?`, `processed?`, `record_received`, and `mark_processed`.
`save_delta_link(mailbox:, folder:, delta_link:, last_polled_at:)` must atomically save the cursor and poll timestamp; `last_polled_at(mailbox:, folder:)` returns that timestamp as a `Time`.

## Polling schedule

The poller is safe to invoke from a recurring job or process scheduler:

```ruby
ActionMailboxGraph.poller.call
```

Or run the included task from cron, a Kubernetes CronJob, or your platform's recurring-job service:

```sh
bin/rails action_mailbox_graph:poll
```

Schedule it at the interval your application needs and ensure only one poller runs for a mailbox at a time.
The first poll establishes and saves a delta baseline without importing pre-existing mail; later polls use the saved delta link to fetch new messages.
Initial delta requests use Graph's `changeType=created` option so later read-status or content updates do not import historical messages. Graph encodes this option into its continuation links.
The poller follows all Graph delta pages, persists the final delta link, and resets to a fresh delta query when Graph expires a link with HTTP 410.
After an expired cursor, it scans the entire watched folder and hands off messages received at or after the last successful poll's start time, with a five-minute overlap. Existing receipts prevent repeat handoff.
The cursor and poll-start timestamp advance together only after every page succeeds. A failed recovery retains the previous checkpoint for the next attempt; first-ever startup remains baseline-only.
The included Active Record store keeps delta state and Graph-message receipts in the application's database.
It avoids handing the same Graph message to Action Mailbox twice across poller restarts and retries marking/moving a handed-off message if that final Graph operation previously failed.

## Local development with Azure CLI

Azure CLI provides a developer token provider so local development does not require a managed identity:

```ruby
ActionMailboxGraph.configure do |config|
  config.mailbox = ENV.fetch("EXCHANGE_SHARED_MAILBOX")
  config.token_provider = ActionMailboxGraph::AzureCliTokenProvider.new
end
```

Sign in with `az login` using a development identity, and ensure that identity has the required delegated Graph permissions and Exchange mailbox access for the shared mailbox.
Production managed-identity role assignments do not grant local developer access.
Tests can inject a token provider responding to `token`, `ActionMailboxGraph::StaticTokenProvider`, or a callable returning `ActionMailboxGraph::Token.new(access_token: "test-token", expires_at: Time.now.to_i + 3600)`.
Callable token results must be `ActionMailboxGraph::Token` objects with a string access token and an integer Unix expiry timestamp.

## One-time tenant administrator setup

Repeat the identity and role setup for each environment so development, staging, and production credentials remain isolated.
These steps grant Exchange access to one named mailbox without a stored client secret or unscoped Microsoft Entra application permission.

1. Create a user-assigned managed identity for the environment and attach it to the app host.
For example, create it with `az identity create --resource-group <resource-group> --name <identity-name>`.
Record the `clientId` and `principalId` returned by Azure as its client ID and service principal object ID.
Set `AZURE_MAIL_IDENTITY_CLIENT_ID` to the client ID.
For Azure Container Apps and App Service, ensure the corresponding managed identity endpoint is enabled for that identity.
2. Connect to Exchange Online PowerShell using an administrator authorized to manage mailboxes and Application RBAC.
Create a shared mailbox and set a unique Exchange custom attribute on it:

   ```powershell
   Connect-ExchangeOnline
   New-Mailbox -Shared -Name "Production App Mailbox" -PrimarySmtpAddress "shared-mailbox@example.com"
   Set-Mailbox "shared-mailbox@example.com" -CustomAttribute1 "ActionMailboxGraphProd"
   ```

3. Create a recipient scope that matches only the shared mailbox:

   ```powershell
   New-ManagementScope -Name "ActionMailboxGraphProd" `
     -RecipientRestrictionFilter "CustomAttribute1 -eq 'ActionMailboxGraphProd'"
   ```

4. Register the managed identity's Entra service principal pointer in Exchange Online.
Use the identity's application/client ID as `-AppId` and its enterprise application service principal object ID as `-ObjectId`:

   ```powershell
   New-ServicePrincipal -AppId <client-id> -ObjectId <service-principal-object-id> `
     -DisplayName "Action Mailbox Graph Production"
   ```

5. Assign only the mail roles this gem uses, both scoped to the mailbox:

   ```powershell
   New-ManagementRoleAssignment -App <service-principal-object-id> `
     -Role "Application Mail.ReadWrite" -CustomResourceScope "ActionMailboxGraphProd"
   New-ManagementRoleAssignment -App <service-principal-object-id> `
     -Role "Application Mail.Send" -CustomResourceScope "ActionMailboxGraphProd"
   ```

6. Verify that each permission is in scope for the target shared mailbox and out of scope for a different mailbox:

   ```powershell
   Test-ServicePrincipalAuthorization -Identity <service-principal-object-id> `
     -Resource "shared-mailbox@example.com" | Format-Table
   Test-ServicePrincipalAuthorization -Identity <service-principal-object-id> `
     -Resource "unrelated-mailbox@example.com" | Format-Table
   ```

   Confirm `Application Mail.ReadWrite` and `Application Mail.Send` show `InScope = True` for the target and `InScope = False` for the unrelated mailbox.
Check the identity's Microsoft Entra permissions and remove any organization-wide `Mail.ReadWrite` or `Mail.Send` grants; Entra grants are additive to Exchange RBAC and would defeat mailbox scoping.

Shared mailboxes usually need no separate license and do not need a human-operated user account for this app-only integration.
Microsoft 365 creates an associated account for a shared mailbox, but this integration authenticates as the managed identity and does not sign in as that account.
A license can be needed when a shared mailbox exceeds its unlicensed storage limit or uses features such as archive or litigation hold.
Create and license a normal user account only if your organization requires interactive sign-in, delegated user authentication, or another mailbox feature that needs a user identity.

## Security and operational notes

The no-logging guarantee covers gem-owned logs and delivery instrumentation: these do not log message content, recipients, attachments, access tokens, request headers, or Graph response bodies.
Action Mailer's delivery instrumentation is suppressed for the Microsoft Graph delivery method.
Rails job logs are controlled by the application. For apps using `deliver_later`, disable argument logging in an initializer so recipients and other sensitive mailer arguments stay out of enqueue and execution logs:

```ruby
ActionMailer::MailDeliveryJob.log_arguments = false
```

Apply the same setting to a custom delivery job if the app uses one, and review application callbacks and logging separately.
Graph request errors include status codes and generic messages only.
Retry attempts are bounded and honor Graph's `Retry-After` header for HTTP 429, 503, and 504 responses.

Microsoft Graph delta links are opaque; treat the database values as sensitive operational state and do not edit them manually.
The database receipts contain Graph message IDs and Action Mailbox record IDs, not message content.
Use Action Mailbox's normal data retention and incineration settings for the stored raw MIME.

## Supported behavior

- Send complete rendered MIME through Graph `sendMail`.
- Poll one configured mailbox folder using Graph message delta and fetch new messages as raw MIME.
- Pass messages to the regular Action Mailbox ingress API for asynchronous routing.
- Mark each handed-off message read or move it to a configured processed folder.
- Select a user-assigned Azure managed identity, use Azure CLI during local development, or inject a test token provider.

Webhooks and change notifications are not implemented; polling is the supported ingress mode.
