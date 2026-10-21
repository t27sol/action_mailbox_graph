require_relative "lib/action_mailbox_graph/version"

Gem::Specification.new do |spec|
  spec.name = "action_mailbox_graph"
  spec.version = ActionMailboxGraph::VERSION
  spec.authors = ["t27sol"]
  spec.summary = "Rails Action Mailbox and Action Mailer integration for Microsoft Graph"
  spec.description = "Poll Exchange Online mailboxes through Microsoft Graph and deliver mail as MIME."
  spec.homepage = "https://github.com/t27sol/action_mailbox_graph"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*", "MIT-LICENSE", "README.md"]
  spec.require_paths = ["lib"]
  spec.add_dependency "rails", ">= 8.0", "< 9.0"
  spec.add_dependency "mail", ">= 2.8", "< 3.0"
end
