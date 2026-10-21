# frozen_string_literal: true

namespace :action_mailbox_graph do
  desc 'Poll the configured Microsoft Graph mailbox and hand new messages to Action Mailbox'
  task poll: :environment do
    ActionMailboxGraph.poller.call
  end
end
