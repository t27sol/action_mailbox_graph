# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'stringio'
require_relative '../lib/action_mailbox_graph'

WebMock.disable_net_connect!

class GraphPrivacyMailer < ActionMailer::Base
  def notice(recipient = 'private-recipient-marker@example.test')
    attachments['private-attachment-marker.txt'] = 'private-attachment-content-marker'
    mail(from: 'sender@example.test', to: recipient,
         cc: 'private-cc-marker@example.test', bcc: 'private-bcc-marker@example.test',
         subject: 'private-subject-marker', body: 'private-body-marker')
  end
end

class DeliveryMethodTest < Minitest::Test
  def setup
    configuration = ActionMailboxGraph::Configuration.new
    configuration.mailbox = 'shared@example.test'
    configuration.token_provider = ActionMailboxGraph::StaticTokenProvider.new('private-token-marker')
    GraphPrivacyMailer.delivery_method = :microsoft_graph
    GraphPrivacyMailer.microsoft_graph_settings = { client: ActionMailboxGraph::Client.new(configuration) }
    GraphPrivacyMailer.perform_deliveries = true
    GraphPrivacyMailer.raise_delivery_errors = true
    @original_logger = ActionMailer::Base.logger
    @logs = StringIO.new
    ActionMailer::Base.logger = ActiveSupport::Logger.new(@logs)
    ActionMailer::Base.logger.level = Logger::DEBUG
  end

  def teardown
    ActionMailer::Base.logger = @original_logger
  end

  def test_graph_delivery_preserves_to_cc_bcc_and_suppresses_mail_payload_logs
    submitted = nil
    request = stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
              .with { |http| submitted = Base64.strict_decode64(http.body) }
              .to_return(status: 202)
    events = []
    delivered = nil

    ActiveSupport::Notifications.subscribed(->(*args) { events << args.last }, 'deliver.action_mailer') do
      delivered = GraphPrivacyMailer.notice.deliver_now
    end

    assert_requested request
    message = Mail.read_from_string(submitted)
    assert_equal ['private-recipient-marker@example.test'], message.to
    assert_equal ['private-cc-marker@example.test'], message.cc
    assert_equal ['private-bcc-marker@example.test'], message.bcc
    assert_equal 'private-body-marker', message.text_part.body.decoded
    assert_equal 'private-attachment-content-marker', message.attachments.first.body.decoded
    assert_nil Mail.read_from_string(delivered.encoded).bcc
    assert_empty events
    assert_includes @logs.string, 'GraphPrivacyMailer#notice'
    assert_private_logs
  end

  def test_graph_delivery_failure_preserves_error_and_restores_bcc_without_logging_payload
    stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
      .to_return(status: 400, body: 'private-body-marker')
    delivery = GraphPrivacyMailer.notice
    message = delivery.message

    assert_raises(ActionMailboxGraph::RequestError) { delivery.deliver_now }

    assert_equal ['private-bcc-marker@example.test'], message.bcc
    assert_nil Mail.read_from_string(message.encoded).bcc
    assert_private_logs
  end

  def test_graph_delivery_skips_transport_when_deliveries_are_disabled
    delivery = GraphPrivacyMailer.notice
    delivery.message.perform_deliveries = false

    delivery.deliver_now

    assert_not_requested :post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail'
    assert_private_logs
  end

  def test_graph_delivery_force_sends_without_logging_payload_when_deliveries_are_disabled
    request = stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
              .to_return(status: 202)
    delivery = GraphPrivacyMailer.notice
    delivery.message.perform_deliveries = false

    assert_same delivery.message, delivery.deliver_now!

    assert_requested request
    assert_private_logs
  end

  def test_direct_mail_delivery_exposes_settings_and_returns_the_requested_transport_response
    request = stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
              .to_return(status: 202)
    message = GraphPrivacyMailer.notice.message
    settings = GraphPrivacyMailer.microsoft_graph_settings.merge(return_response: true)
    message.delivery_method(ActionMailboxGraph::DeliveryMethod, settings)

    response = message.deliver!

    assert_equal settings, message.delivery_method.settings
    assert_equal '202', response.code
    assert_requested request, times: 1
    assert_nil Mail.read_from_string(message.encoded).bcc
  end

  def test_deliver_later_keeps_sensitive_mail_out_of_logs_with_documented_job_configuration
    job_class = ActionMailer::MailDeliveryJob
    original_arguments = job_class.log_arguments
    original_adapter = job_class.queue_adapter
    original_logger = ActiveJob::Base.logger
    job_class.log_arguments = false
    job_class.queue_adapter = :inline
    ActiveJob::Base.logger = ActionMailer::Base.logger
    request = stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
              .to_return(status: 202)

    GraphPrivacyMailer.notice('private-recipient-marker@example.test').deliver_later

    assert_requested request, times: 1
    assert_includes @logs.string, 'Enqueued ActionMailer::MailDeliveryJob'
    assert_includes @logs.string, 'Performing ActionMailer::MailDeliveryJob'
    assert_private_logs
  ensure
    job_class.log_arguments = original_arguments
    job_class.queue_adapter = original_adapter
    ActiveJob::Base.logger = original_logger
  end

  def test_other_delivery_methods_retain_action_mailer_instrumentation
    GraphPrivacyMailer.delivery_method = :test
    events = []

    ActiveSupport::Notifications.subscribed(->(*args) { events << args.last }, 'deliver.action_mailer') do
      GraphPrivacyMailer.notice.deliver_now
    end

    assert_equal 1, events.length
    assert_equal ['private-recipient-marker@example.test'], events.first[:to]
    assert_includes @logs.string, 'private-body-marker'
  end

  private

  def assert_private_logs
    markers = %w[private-recipient-marker private-cc-marker private-bcc-marker private-subject-marker
                 private-body-marker private-attachment-marker private-attachment-content-marker private-token-marker]
    markers.each do |marker|
      refute_includes @logs.string, marker
      refute_includes @logs.string, Base64.strict_encode64(marker)
    end
  end
end
