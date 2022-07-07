# frozen_string_literal: true

require "discorb"
require "dotenv/load"
require "octokit"
require "securerandom"
require "i18n"

require_relative "db/models"

client = Discorb::Client.new
I18n.load_path << Dir["locale.yml"]

client.once :standby do
  puts "Logged in as #{client.user}"
end

client.on(:message) do |message|
  next if message.author.bot?

  message.content.scan(/\#\#(\d+)/) do
    # @type var issue_num: Integer
    next unless issue_num = Regexp.last_match[1].to_i
  end
end

client.slash "login", "Register your PAT of GitHub", {} do |interaction|
  I18n.locale = interaction.locale
  nonce = SecureRandom.hex(16)
  interaction.post(
    embed: Discorb::Embed.new(
      ":inbox_tray: " + I18n.t("login.title"),
      I18n.t("login.description"),
      color: Discorb::Color[:gray],
    ),
    components: [
      Discorb::Button.new(
        I18n.t("login.register"),
        custom_id: nonce + ":1",
      ),
    ],
    ephemeral: true,
  )
  button_interaction = client.event_lock(:button_click) { |i| i.custom_id == nonce + ":1" }.wait
  button_interaction.show_modal(I18n.t("login.modal_title"), nonce + ":2", [
    Discorb::TextInput.new(
      I18n.t("login.modal_title"),
      "pat",
      :short,
      required: true,
    ),
  ]).wait
  modal_interaction = client.event_lock(:modal_submit) { |i| i.custom_id == nonce + ":2" }.wait

  modal_interaction.defer_source(ephemeral: true).wait

  pat = Pat.new(pat: modal_interaction.contents["pat"], guild_id: interaction.guild.id)
  begin
    user = pat.client.user
  rescue Octokit::Unauthorized
    next interaction.post(I18n.t("login.invalid"), ephemeral: true)
  end
  pat.save
  modal_interaction.post(I18n.t("login.success", login: user.login, name: user.name), ephemeral: true)
end

client.run ENV["TOKEN"]
