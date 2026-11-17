# frozen_string_literal: true

RSpec.describe ReviewableFlaggedPost do
  describe "#perform" do
    fab!(:moderator)
    fab!(:flagger) { Fabricate(:user, refresh_auto_groups: true) }
    fab!(:post)

    let(:rule) do
      {
        "ground" => "Community Guidelines: Be agreeable",
        "explanation" => "Personal attacks are not allowed.",
      }
    end
    let(:classification) do
      { community_rule: rule, category: DsaStatementOfRecord::TERMS_VIOLATION_CATEGORY }
    end
    let(:flag_reason) { I18n.t("flag_reasons.inappropriate", base_path: Discourse.base_path) }
    let(:paragraph) do
      "More specifically, your post violated the following community guideline: **#{rule["ground"]}**. #{rule["explanation"]}"
    end

    before do
      enable_dsa_reporting(community_rules: [rule])
      SiteSetting.dsa_moderation_appeal_email = "appeals@example.com"
    end

    def existing_notice(
      type:,
      recipient: post.user,
      flag_reason: self.flag_reason,
      reply: nil,
      appeal: true
    )
      options = {
        url: post.url,
        edit_delay: SiteSetting.cooldown_minutes_after_hiding_posts,
        flagged_post_raw_content: post.raw,
        flagged_post_response_raw_content: reply&.raw,
        flag_reason:,
      }
      if appeal
        options.merge!(
          body_suffix_key: "system_messages.moderation_appeal_instructions",
          email: "appeals@example.com",
        )
      end

      SystemMessage.create(recipient, type, options)
    end

    def expect_notice(args:, baseline:, paragraph: nil, flag_reason: self.flag_reason)
      expected_body = baseline.raw
      expected_body = expected_body.sub(flag_reason, "#{flag_reason}\n\n#{paragraph}") if paragraph

      Jobs::SendSystemMessage.new.perform(args)

      expect(Post.last.raw).to eq(expected_body)
      expect(Post.last.topic.title).to eq(baseline.topic.title)
      expect(Post.last.topic.allowed_users).to match_array(baseline.topic.allowed_users)
    end

    it "adds only the selected rule to the existing notice for agree_and_hide" do
      baseline = existing_notice(type: :post_hidden)
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :agree_and_hide, dsa_classification: classification)

      expect_notice(args: Jobs::SendSystemMessage.jobs.sole["args"].first, baseline:, paragraph:)
    end

    it "adds only the selected rule to the existing notice for delete_and_agree" do
      baseline = existing_notice(type: :flags_agreed_and_post_deleted)
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :delete_and_agree, dsa_classification: classification)

      expect_notice(args: Jobs::SendSystemMessage.jobs.sole["args"].first, baseline:, paragraph:)
    end

    it "adds only the selected rule to the existing notice for delete_and_ignore" do
      baseline = existing_notice(type: :flags_agreed_and_post_deleted)
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :delete_and_ignore, dsa_classification: classification)

      expect_notice(args: Jobs::SendSystemMessage.jobs.sole["args"].first, baseline:, paragraph:)
    end

    it "adds the correct rule paragraph to the author and responder notices for delete_and_agree_replies" do
      reply =
        PostCreator.create!(
          Fabricate(:user),
          topic_id: post.topic_id,
          reply_to_post_number: post.post_number,
          raw: "Please keep the discussion respectful.",
        )
      post.reload
      baseline = existing_notice(type: :flags_agreed_and_post_deleted)
      responder_reason =
        I18n.t("flag_reasons.responder.inappropriate", base_path: Discourse.base_path)
      responder_baseline =
        existing_notice(
          type: :flags_agreed_and_post_deleted_for_responders,
          recipient: reply.user,
          flag_reason: responder_reason,
          reply:,
        )
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      SiteSetting.notify_users_after_responses_deleted_on_flagged_post = true
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :delete_and_agree_replies, dsa_classification: classification)

      notices = Jobs::SendSystemMessage.jobs.map { |job| job["args"].first }
      expect(notices.size).to eq(2)
      expect_notice(
        args: notices.find { |notice| notice["user_id"] == post.user_id },
        baseline:,
        paragraph:,
      )
      expect_notice(
        args: notices.find { |notice| notice["user_id"] == reply.user_id },
        baseline: responder_baseline,
        flag_reason: responder_reason,
        paragraph:
          "More specifically, the post you replied to violated the following community guideline: **#{rule["ground"]}**. #{rule["explanation"]}",
      )
    end

    it "adds the correct rule paragraph to the author and responder notices for delete_and_ignore_replies" do
      reply =
        PostCreator.create!(
          Fabricate(:user),
          topic_id: post.topic_id,
          reply_to_post_number: post.post_number,
          raw: "Please keep the discussion respectful.",
        )
      post.reload
      baseline = existing_notice(type: :flags_agreed_and_post_deleted)
      responder_reason =
        I18n.t("flag_reasons.responder.inappropriate", base_path: Discourse.base_path)
      responder_baseline =
        existing_notice(
          type: :flags_agreed_and_post_deleted_for_responders,
          recipient: reply.user,
          flag_reason: responder_reason,
          reply:,
        )
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      SiteSetting.notify_users_after_responses_deleted_on_flagged_post = true
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :delete_and_ignore_replies, dsa_classification: classification)

      notices = Jobs::SendSystemMessage.jobs.map { |job| job["args"].first }
      expect(notices.size).to eq(2)
      expect_notice(
        args: notices.find { |notice| notice["user_id"] == post.user_id },
        baseline:,
        paragraph:,
      )
      expect_notice(
        args: notices.find { |notice| notice["user_id"] == reply.user_id },
        baseline: responder_baseline,
        flag_reason: responder_reason,
        paragraph:
          "More specifically, the post you replied to violated the following community guideline: **#{rule["ground"]}**. #{rule["explanation"]}",
      )
    end

    it "adds only the selected rule to the existing notice when hiding an edited post again" do
      post.update!(hidden_at: 1.day.ago)
      baseline = existing_notice(type: :post_hidden_again)
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :agree_and_hide, dsa_classification: classification)

      expect_notice(args: Jobs::SendSystemMessage.jobs.sole["args"].first, baseline:, paragraph:)
    end

    it "preserves the custom flag and classification copy when configuration changes before delivery" do
      flag = Fabricate(:flag, name: "Unmarked spoilers", notify_type: true)
      baseline = existing_notice(type: :flags_agreed_and_post_deleted, flag_reason: flag.name)
      original_name = flag.name
      reviewable = PostActionCreator.create(flagger, post, flag.name_key.to_sym).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :delete_and_agree, dsa_classification: classification)
      flag.update!(name: "Changed name")
      SiteSetting.dsa_reporting_enabled = false
      SiteSetting.dsa_community_rules = [].to_json
      SiteSetting.dsa_moderation_appeal_email = "changed@example.com"

      expect_notice(
        args: Jobs::SendSystemMessage.jobs.sole["args"].first,
        baseline:,
        paragraph:,
        flag_reason: original_name,
      )
    end

    it "preserves the existing notice when DSA reporting is disabled" do
      SiteSetting.dsa_reporting_enabled = false
      baseline = existing_notice(type: :post_hidden, appeal: false)
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :agree_and_hide, dsa_classification: classification)

      expect_notice(args: Jobs::SendSystemMessage.jobs.sole["args"].first, baseline:)
    end

    it "preserves the existing notice and appeal instructions when no classification is selected" do
      baseline = existing_notice(type: :post_hidden)
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :agree_and_hide)

      expect_notice(args: Jobs::SendSystemMessage.jobs.sole["args"].first, baseline:)
    end

    it "renders a customized template with the reason and localized classification captured before delivery" do
      SiteSetting.allow_user_locale = true
      SiteSetting.default_locale = "en"
      post.user.update!(locale: "fr")
      TranslationOverride.upsert!(
        :fr,
        "system_messages.moderation_reason",
        "Plus précisément : **%{ground}**. %{explanation}",
      )
      TranslationOverride.upsert!(
        :en,
        "system_messages.post_hidden.text_body_template",
        "Before the reason.\n\n%{flag_reason}\n\nAfter the reason.",
      )
      original_reason = flag_reason
      reviewable = PostActionCreator.inappropriate(flagger, post).reviewable
      Jobs::SendSystemMessage.clear

      reviewable.perform(moderator, :agree_and_hide, dsa_classification: classification)
      post.user.update!(locale: "en")
      SiteSetting.default_locale = "de"
      TranslationOverride.upsert!(:en, "flag_reasons.inappropriate", "Changed flag description.")
      baseline = existing_notice(type: :post_hidden, flag_reason: original_reason)

      expect_notice(
        args: Jobs::SendSystemMessage.jobs.sole["args"].first,
        baseline:,
        flag_reason: original_reason,
        paragraph: "Plus précisément : **#{rule["ground"]}**. #{rule["explanation"]}",
      )
    end
  end
end
