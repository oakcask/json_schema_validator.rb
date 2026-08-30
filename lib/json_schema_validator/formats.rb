# frozen_string_literal: true

require "ipaddr"

module JsonSchemaValidator
  module Internal
    module Formats
      class << self
        def valid?(format, value)
          case format
          when "date" then valid_date?(value)
          when "time" then valid_time?(value)
          when "date-time" then valid_date_time?(value)
          when "ipv4" then IPAddr.new(value).ipv4?
          else true
          end
        rescue IPAddr::InvalidAddressError
          false
        end

        private def valid_date?(value)
          value.bytesize == 10 && valid_date_at?(value, 0)
        end

        private def valid_date_at?(value, start)
          return false unless value.getbyte(start + 4) == 45 && value.getbyte(start + 7) == 45

          year = ascii_number(value, start, 4)
          month = ascii_number(value, start + 5, 2)
          day = ascii_number(value, start + 8, 2)
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

          hour = ascii_number(value, start, 2)
          minute = ascii_number(value, start + 3, 2)
          second = ascii_number(value, start + 6, 2)
          return false unless hour&.between?(0, 23) && minute&.between?(0, 59) && second&.between?(0, 60)

          index = start + 8
          if value.getbyte(index) == 46
            index += 1
            fraction_start = index
            index += 1 while ascii_digit?(value.getbyte(index))
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

            offset_hour = ascii_number(value, index + 1, 2)
            offset_minute = ascii_number(value, index + 4, 2)
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

        private def ascii_number(value, start, length)
          number = 0
          offset = 0
          while offset < length
            byte = value.getbyte(start + offset)
            return unless ascii_digit?(byte)

            number = (number * 10) + byte - 48
            offset += 1
          end
          number
        end

        private def ascii_digit?(byte)
          byte && byte.between?(48, 57)
        end

        private def leap_year?(year)
          (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)
        end
      end
    end
  end

  private_constant :Internal
end
