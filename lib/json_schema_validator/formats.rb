# frozen_string_literal: true

require "ipaddr"

module JsonSchemaValidator
  module Internal
    module Formats
      Format = Data.define(:name)

      UNKNOWN = Format.new(nil)
      DATE = Format.new("date")
      TIME = Format.new("time")
      DATE_TIME = Format.new("date-time")
      IPV4 = Format.new("ipv4")

      class << self
        def resolve(format)
          case format
          when "date" then DATE
          when "time" then TIME
          when "date-time" then DATE_TIME
          when "ipv4" then IPV4
          else UNKNOWN
          end
        end

        def valid?(format, value)
          if format.equal?(DATE)
            valid_date?(value)
          elsif format.equal?(TIME)
            valid_time?(value)
          elsif format.equal?(DATE_TIME)
            valid_date_time?(value)
          elsif format.equal?(IPV4)
            IPAddr.new(value).ipv4?
          else
            true
          end
        rescue IPAddr::InvalidAddressError
          false
        end

        private def valid_date?(value)
          value.bytesize == 10 && valid_date_at?(value, 0)
        end

        private def valid_date_at?(value, start)
          return false unless value.getbyte(start + 4) == 45 && value.getbyte(start + 7) == 45

          century = two_digits(value, start)
          year_in_century = two_digits(value, start + 2)
          month = two_digits(value, start + 5)
          day = two_digits(value, start + 8)
          return false unless century && year_in_century

          year = (century * 100) + year_in_century
          return false unless year && month && day && month.between?(1, 12)

          last_day = if month == 2
            leap_year?(year) ? 29 : 28
          elsif month == 4 || month == 6 || month == 9 || month == 11
            30
          else
            31
          end
          day.between?(1, last_day)
        end

        private def valid_time?(value)
          valid_time_at?(value, 0)
        end

        private def valid_time_at?(value, start)
          return false if value.bytesize < start + 9
          return false unless value.getbyte(start + 2) == 58 && value.getbyte(start + 5) == 58

          hour = two_digits(value, start)
          minute = two_digits(value, start + 3)
          second = two_digits(value, start + 6)
          return false unless hour&.between?(0, 23) && minute&.between?(0, 59) && second&.between?(0, 60)

          index = start + 8
          if value.getbyte(index) == 46
            index += 1
            fraction_start = index
            while (byte = value.getbyte(index)) && byte >= 48 && byte <= 57
              index += 1
            end
            return false if index == fraction_start
          end

          zone = value.getbyte(index)
          if zone == 90 || zone == 122
            return false unless index + 1 == value.bytesize
            offset = 0
          else
            return false unless zone == 43 || zone == 45
            return false unless index + 6 == value.bytesize
            return false unless value.getbyte(index + 3) == 58

            offset_hour = two_digits(value, index + 1)
            offset_minute = two_digits(value, index + 4)
            return false unless offset_hour&.between?(0, 23) && offset_minute&.between?(0, 59)

            offset = (offset_hour * 60) + offset_minute
            offset = -offset if zone == 45
          end

          second != 60 || ((hour * 60) + minute - offset) % 1_440 == 1_439
        end

        private def valid_date_time?(value)
          value.bytesize >= 20 &&
            valid_date_at?(value, 0) &&
            (value.getbyte(10) == 84 || value.getbyte(10) == 116) &&
            valid_time_at?(value, 11)
        end

        private def two_digits(value, start)
          tens = value.getbyte(start) - 48
          ones = value.getbyte(start + 1) - 48
          return unless tens.between?(0, 9) && ones.between?(0, 9)

          (tens * 10) + ones
        end

        private def leap_year?(year)
          (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)
        end
      end

      private_constant :Format, :UNKNOWN, :DATE, :TIME, :DATE_TIME, :IPV4
    end
  end

  private_constant :Internal
end
