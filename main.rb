# frozen_string_literal: true

require "discorb"
require "dotenv/load"
require "octokit"
require "securerandom"
require "i18n"

require_relative "db/models"

client = Discorb::Client.new
repositories = Hash.new { |h, k| h[k] = [] }.merge(Repo.all.group_by(&:guild_id))
pats = Pat.all.to_a.to_h { |pat| [pat.guild_id, pat] }
I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
I18n.load_path << Dir["locale/*.yml"]
I18n.default_locale = :en
I18n.fallbacks = [:en]
I18n.enforce_available_locales = false

def all_translations(key)
  translations = I18n.available_locales.to_h { |l| [l, I18n.t(key, locale: l, default: nil)] }
  translations[:default] = translations[:en]
  translations[:en_us] = translations[:en]
  translations.delete(:en)  # en doesn't work on discord
  translations.compact!
  translations
end

client.once :standby do
  puts "Logged in as #{client.user}"
end

client.on(:message) do |message|
  next if message.author.bot?
  next unless pat = pats[message.guild.id]

  guild_repos = repositories[message.guild.id]
  channel_repos = guild_repos.filter { |repo| repo.channel_id == message.channel.id or repo.channel_id.nil? }
  issues = []
  catch :stop do
    channel_repos.each do |repo|
      message.clean_content.scan(/\b(#{repo.prefix}([0-9]+))/) do |match|
        begin
          issue = pat.client.issue(repo.repo, match[1])
        rescue Octokit::Unauthorized, Octokit::TooManyRequests
          throw :stop
        rescue Octokit::NotFound
          next
        end
        issues << [match[0], issue]
      end
    end
  end
  next if issues.empty?
  issues.uniq!(&:first)

  embed = Discorb::Embed.new(
    "",
    issues.map do |match, issue|
      "[`#{match}` #{issue.title.truncate(50)}](#{issue.html_url})"
    end.join("\n")
  )
  next unless embed.description.present?

  message.reply embed: embed
end

client.slash("login", all_translations("login.description"), dm_permission: false, default_permission: Discorb::Permission.from_keys(:administrator)) do |interaction|
  I18n.locale = interaction.locale
  nonce = SecureRandom.hex(16)
  interaction.post(
    I18n.t("login.prompt"),
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

  pat = Pat.new(pat: modal_interaction.contents["pat"], guild_id: interaction.guild.id, user_id: interaction.user.id)
  begin
    user = pat.client.user
  rescue Octokit::Unauthorized
    next interaction.post(I18n.t("login.invalid"), ephemeral: true)
  end
  Pat.where(guild_id: interaction.guild.id).delete_all
  pat.save
  pats[interaction.guild.id] = pat
  modal_interaction.post(I18n.t("login.success", login: user.login, name: user.name), ephemeral: true)
end

client.slash_group "repo", all_translations("repo.description"), default_permission: Discorb::Permission.from_keys(:manage_webhooks), dm_permission: false do |group|
  group.slash("list", all_translations("repo.list.description"), {}) do |interaction|
    # @type var interaction: Discorb::CommandInteraction::ChatInputCommand
    I18n.locale = interaction.locale

    interaction.defer_source(ephemeral: true).wait
    repos = Repo.where(guild_id: interaction.guild.id)
    if repos.empty?
      interaction.edit_original_message(
        embed: Discorb::Embed.new(
          I18n.t("repo.list.title"), I18n.t("repo.list.no_repos"),
        ),
      )
      next
    end
    page = 0
    max_pages = (repos.count / 10.0).ceil
    nonce = SecureRandom.hex(16)

    left = Discorb::Button.new(I18n.t("repo.list.left"), :primary, custom_id: nonce + ":left")
    right = Discorb::Button.new(I18n.t("repo.list.right"), :primary, custom_id: nonce + ":right")
    stop = Discorb::Button.new(I18n.t("repo.list.stop"), :danger, custom_id: nonce + ":stop")

    loop do
      left.disabled = page == 0
      right.disabled = page == max_pages - 1
      interaction.edit_original_message(
        embed: Discorb::Embed.new(
          I18n.t("repo.list.title"),
          I18n.t("repo.list.status", count: repos.count, page: page + 1),
          fields: repos.offset(page * 10).limit(10).map do |repo|
            Discorb::Embed::Field.new(
              repo.repo,
              I18n.t(
                "repo.list.text",
                prefix: repo.prefix,
                channel: client.channels[repo.channel_id]&.mention || I18n.t("repo.list.no_channel"),
              )
            )
          end,
        ),
        components: [
          [left, right, stop],
        ],
      ).wait
      button_interaction = client.event_lock(:button_click, 30) { |i| i.custom_id.start_with?(nonce) }.wait
      case button_interaction.custom_id.delete_prefix(nonce + ":")
      when "left"
        page -= 1
      when "right"
        page += 1
      when "stop"
        break
      end
      button_interaction.defer_update.wait
    end
    interaction.edit_original_message(components: []).wait
  rescue Discorb::TimeoutError
    interaction.edit_original_message(components: []).wait
  end

  group.slash(
    "add", all_translations("repo.add.description"), {
      "repo" => {
        type: :string,
        description: all_translations("repo.add.parameters.repo"),
      },
      "prefix" => {
        type: :string,
        length: 1..,
        description: all_translations("repo.add.parameters.prefix"),
        optional: true,
      },
      "channel" => {
        type: :channel,
        channel_types: [Discorb::TextChannel],
        description: all_translations("repo.add.parameters.channel"),
        optional: true,
      },
    },
  ) do |interaction, repo_name, prefix, channel|
    I18n.locale = interaction.locale

    prefix ||= "#"
    pat = Pat.find_by(guild_id: interaction.guild.id)
    unless pat
      interaction.post(I18n.t("repo.add.no_pat"), ephemeral: true)
      next
    end
    interaction.defer_source(ephemeral: true).wait
    repos = Repo.where(prefix: prefix, guild_id: interaction.guild.id).all.to_a
    repos.filter! { |r| r.channel_id == channel.id } if channel

    unless repos.empty?
      interaction.post(I18n.t("repo.add.duplicate"), ephemeral: true)
      next
    end
    begin
      repo = pat.client.repo(repo_name)
    rescue Octokit::Unauthorized
      interaction.post(I18n.t("common.unauthorized"), ephemeral: true)
      next
    rescue Octokit::InvalidRepository
      interaction.post(I18n.t("repo.add.invalid"), ephemeral: true)
      next
    rescue Octokit::NotFound
      interaction.post(I18n.t("repo.add.not_found"), ephemeral: true)
      next
    end
    repo = Repo.create(repo: repo.full_name, prefix: prefix, channel_id: channel&.id, guild_id: interaction.guild.id)
    repositories[interaction.guild.id] << repo
    interaction.post(I18n.t("repo.add.success"), ephemeral: true)
  end

  group.slash(
    "remove", all_translations("repo.remove.description"), {
      "repo" => {
        type: :integer,
        description: all_translations("repo.remove.parameters.repo"),
        autocomplete: ->(interaction, query) {
          I18n.locale = interaction.locale
          repos = Repo.where(
            Repo.arel_table[:repo].matches("%#{query}%"),
            guild_id: interaction.guild.id,
          )
          repos.limit(25).each.map { |r|
            [
              "#{r.repo} (#{r.prefix}) @ #{r.channel_id ? "#" + client.channels[r.channel_id].name : I18n.t("repo.list.no_channel")}",
              r.id,
            ]
          }
        },
      },
    },
  ) do |interaction, repo|
    I18n.locale = interaction.locale

    repo = Repo.find_by(id: repo, guild_id: interaction.guild.id)
    next unless repo

    repo.destroy
    interaction.post(I18n.t("repo.remove.success"), ephemeral: true)
  end
end

client.slash_group "info", all_translations("info.description") do |group|
  group.slash "bot", all_translations("info.bot.description"), {} do |interaction|
    I18n.locale = interaction.locale

    interaction.post(I18n.t("info.bot.text"), ephemeral: true)
  end

  group.slash "pat", all_translations("info.pat.description"), {} do |interaction|
    I18n.locale = interaction.locale

    pat = Pat.find_by(guild_id: interaction.guild.id)
    unless pat
      interaction.post(I18n.t("info.no_pat"), ephemeral: true)
      next
    end

    interaction.defer_source(ephemeral: true).wait
    user = pat.client.user
    rate_limit = pat.client.rate_limit

    interaction.post(
      I18n.t(
        "info.pat.text",
        discord_user: pat.user_id,
        gh_user: user.name,
        gh_login: user.login,
        rl_remaining: rate_limit.remaining,
        rl_limit: rate_limit.limit,
        rl_reset: rate_limit.resets_at.to_df("R"),
      ),
      ephemeral: true,
    )
  end
end

client.run ENV["TOKEN"]
