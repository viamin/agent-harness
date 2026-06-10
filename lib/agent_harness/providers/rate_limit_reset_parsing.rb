# frozen_string_literal: true

module AgentHarness
  module Providers
    # Shared rate-limit reset time parsing for providers whose CLIs emit
    # standard reset-time formats in error output.
    #
    # Include this module in any provider that uses the common format:
    #   - "retry after 60s"        (seconds)
    #   - "reset at 1234567890"    (unix timestamp)
    #   - "resets 5am (UTC)"       (time today/tomorrow)
    #   - "resets 5:00am (UTC)"    (time with minutes)
    #   - "resets Jan 15, 5pm (UTC)" (date + time)
    #
    # Providers with a different format should override
    # +parse_rate_limit_reset+ directly instead of including this module.
    module RateLimitResetParsing
      # Parse rate-limit reset time from provider error output.
      #
      # @param text [String, nil] error output text
      # @return [Time, nil] UTC reset time, or nil if not parseable
      def parse_rate_limit_reset(text)
        return nil unless text

        parse_retry_after(text) ||
          parse_reset_at(text) ||
          parse_reset_at_datetime(text) ||
          parse_resets_time(text) ||
          parse_resets_date_time(text)
      end

      private

      # "retry after 60s"
      def parse_retry_after(text)
        match = text.match(/retry\s+after\s+(\d+)\s*s/i)
        return unless match

        Time.now.utc + match[1].to_i
      end

      # "reset at 1234567890" (unix timestamp)
      def parse_reset_at(text)
        match = text.match(/reset\s+at\s+(\d{10})/i)
        return unless match

        Time.at(match[1].to_i).utc
      end

      # "reset at 2026-05-18 11:22:32"
      def parse_reset_at_datetime(text)
        match = text.match(/reset\s+at\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})/i)
        return unless match

        Time.strptime("#{match[1]} #{match[2]} UTC", "%Y-%m-%d %H:%M:%S %Z").utc
      rescue ArgumentError
        nil
      end

      # "resets 5am (UTC)" / "resets 5:00am (UTC)"
      def parse_resets_time(text)
        match = text.match(/resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(UTC\)/i)
        return unless match

        hour = match[1].to_i
        minute = match[2]&.to_i || 0
        meridiem = match[3].downcase
        hour = to_24h(hour, meridiem)

        now = Time.now.utc
        reset_time = Time.utc(now.year, now.month, now.day, hour, minute)
        reset_time += 86_400 if reset_time <= now
        reset_time
      end

      # "resets Jan 15, 5pm (UTC)"
      def parse_resets_date_time(text)
        match = text.match(/resets\s+(\w{3})\s+(\d{1,2}),?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(UTC\)/i)
        return unless match

        month = Date::ABBR_MONTHNAMES.index(match[1].capitalize)
        return unless month

        day = match[2].to_i
        hour = match[3].to_i
        minute = match[4]&.to_i || 0
        meridiem = match[5].downcase
        hour = to_24h(hour, meridiem)

        now = Time.now.utc
        candidate = Time.utc(now.year, month, day, hour, minute)
        candidate = Time.utc(now.year + 1, month, day, hour, minute) if candidate < now - 7200

        return nil if candidate >= now + 8 * 86_400

        candidate
      rescue ArgumentError
        nil
      end

      def to_24h(hour, meridiem)
        hour += 12 if meridiem == "pm" && hour != 12
        hour = 0 if meridiem == "am" && hour == 12
        hour
      end
    end
  end
end
