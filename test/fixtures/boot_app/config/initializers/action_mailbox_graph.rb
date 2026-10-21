# frozen_string_literal: true

ActionMailboxGraph.configure do |config|
  config.mailbox = 'shared@example.test'
end

Rails.application.config.action_mailer.delivery_method = :microsoft_graph
ActionMailer::MailDeliveryJob.log_arguments = false
