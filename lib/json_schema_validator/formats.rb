# frozen_string_literal: true

module JsonSchemaValidator
  module Internal
    module Formats
      class Format
        attr_reader :name

        def initialize(name = nil)
          @name = name
          freeze
        end

        def call(_value)
          true
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

        private def valid_duration_time_at?(value, index)
          length = value.bytesize
          number_end = ascii_digits_end(value, index)
          return false unless number_end

          case value.getbyte(number_end)
          when 72 # H
            index = number_end + 1
            if (number_end = ascii_digits_end(value, index))
              return false unless value.getbyte(number_end) == 77 # M

              index = number_end + 1
              if (number_end = ascii_digits_end(value, index))
                return false unless value.getbyte(number_end) == 83 # S

                index = number_end + 1
              end
            end
          when 77 # M
            index = number_end + 1
            if (number_end = ascii_digits_end(value, index))
              return false unless value.getbyte(number_end) == 83 # S

              index = number_end + 1
            end
          when 83 # S
            index = number_end + 1
          else
            return false
          end

          index == length
        end

        private def valid_json_pointer_at?(value, index)
          length = value.bytesize
          return true if index == length
          return false unless value.getbyte(index) == 47 # /

          while index < length
            if value.getbyte(index) == 126 # ~
              index += 1
              return false unless value.getbyte(index) == 48 || value.getbyte(index) == 49 # 0 or 1
            end
            index += 1
          end

          true
        end

        private def ascii_digits_end(value, index)
          start = index
          index += 1 while value.getbyte(index)&.between?(48, 57)
          index unless index == start
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

        private def valid_ipv4_at?(value, index)
          length = value.bytesize

          4.times do |octet|
            byte = value.getbyte(index)
            return false unless byte&.between?(48, 57)
            return false if byte == 48 && value.getbyte(index + 1)&.between?(48, 57)

            number = 0
            digits = 0
            while (byte = value.getbyte(index))&.between?(48, 57)
              number = (number * 10) + byte - 48
              digits += 1
              return false if digits > 3

              index += 1
            end
            return false if number > 255

            if octet == 3
              return false unless index == length
            else
              return false unless value.getbyte(index) == 46

              index += 1
            end
          end

          true
        end
      end

      class DateFormat < Format
        def initialize = super("date")

        def call(value)
          value.bytesize == 10 && valid_date_at?(value, 0)
        end
      end

      class TimeFormat < Format
        def initialize = super("time")

        def call(value)
          valid_time_at?(value, 0)
        end
      end

      class DateTimeFormat < Format
        def initialize = super("date-time")

        def call(value)
          value.bytesize >= 20 &&
            valid_date_at?(value, 0) &&
            (value.getbyte(10) == 84 || value.getbyte(10) == 116) &&
            valid_time_at?(value, 11)
        end
      end

      class DurationFormat < Format
        def initialize = super("duration")

        def call(value)
          length = value.bytesize
          return false unless value.getbyte(0) == 80 && length > 1

          index = 1
          return valid_duration_time_at?(value, index + 1) if value.getbyte(index) == 84 # T

          number_end = ascii_digits_end(value, index)
          return false unless number_end

          case value.getbyte(number_end)
          when 87 # W
            return number_end + 1 == length
          when 89 # Y
            index = number_end + 1
            if (number_end = ascii_digits_end(value, index))
              return false unless value.getbyte(number_end) == 77 # M

              index = number_end + 1
              if (number_end = ascii_digits_end(value, index))
                return false unless value.getbyte(number_end) == 68 # D

                index = number_end + 1
              end
            end
          when 77 # M
            index = number_end + 1
            if (number_end = ascii_digits_end(value, index))
              return false unless value.getbyte(number_end) == 68 # D

              index = number_end + 1
            end
          when 68 # D
            index = number_end + 1
          else
            return false
          end

          return true if index == length
          return false unless value.getbyte(index) == 84 # T

          valid_duration_time_at?(value, index + 1)
        end
      end

      class Ipv4Format < Format
        def initialize = super("ipv4")

        def call(value)
          valid_ipv4_at?(value, 0)
        end
      end

      class Ipv6Format < Format
        def initialize = super("ipv6")

        def call(value)
          length = value.bytesize
          return false if length.zero?

          index = 0
          groups = 0
          compressed = false

          if value.getbyte(index) == 58 # :
            return false unless value.getbyte(index + 1) == 58

            compressed = true
            index += 2
            return true if index == length
          end

          while index < length
            group_start = index
            hex_digits = 0
            while (byte = value.getbyte(index)) &&
                (byte.between?(48, 57) || byte.between?(65, 70) || byte.between?(97, 102))
              hex_digits += 1
              return false if hex_digits > 4

              index += 1
            end
            return false if hex_digits.zero?

            if value.getbyte(index) == 46 # .
              return false unless groups <= 6 && valid_ipv4_at?(value, group_start)

              groups += 2
              index = length
              break
            end

            groups += 1
            return false if groups > 8
            break if index == length
            return false unless value.getbyte(index) == 58 # :

            index += 1
            if value.getbyte(index) == 58 # :
              return false if compressed

              compressed = true
              index += 1
              break if index == length
            elsif index == length
              return false
            end
          end

          compressed ? groups < 8 : groups == 8
        end
      end

      class JsonPointerFormat < Format
        def initialize = super("json-pointer")

        def call(value)
          valid_json_pointer_at?(value, 0)
        end
      end

      class RelativeJsonPointerFormat < Format
        def initialize = super("relative-json-pointer")

        def call(value)
          length = value.bytesize
          first = value.getbyte(0)
          return false unless first&.between?(48, 57)

          index = 1
          return false if first == 48 && value.getbyte(index)&.between?(48, 57)

          index += 1 while value.getbyte(index)&.between?(48, 57)
          return true if index == length
          return index + 1 == length if value.getbyte(index) == 35 # #

          valid_json_pointer_at?(value, index)
        end
      end

      class UuidFormat < Format
        def initialize = super("uuid")

        def call(value)
          return false unless value.bytesize == 36

          36.times do |index|
            byte = value.getbyte(index)
            if index == 8 || index == 13 || index == 18 || index == 23
              return false unless byte == 45 # -
            else
              return false unless byte&.between?(48, 57) || byte&.between?(65, 70) || byte&.between?(97, 102)
            end
          end

          true
        end
      end

      UNKNOWN = Format.new
      DATE = DateFormat.new
      TIME = TimeFormat.new
      DATE_TIME = DateTimeFormat.new
      DURATION = DurationFormat.new
      IPV4 = Ipv4Format.new
      IPV6 = Ipv6Format.new
      JSON_POINTER = JsonPointerFormat.new
      RELATIVE_JSON_POINTER = RelativeJsonPointerFormat.new
      UUID = UuidFormat.new

      class << self
        def resolve(format)
          case format
          when "date" then DATE
          when "time" then TIME
          when "date-time" then DATE_TIME
          when "duration" then DURATION
          when "ipv4" then IPV4
          when "ipv6" then IPV6
          when "json-pointer" then JSON_POINTER
          when "relative-json-pointer" then RELATIVE_JSON_POINTER
          when "uuid" then UUID
          else UNKNOWN
          end
        end
      end

      private_constant :Format, :DateFormat, :TimeFormat, :DateTimeFormat, :DurationFormat,
        :Ipv4Format, :Ipv6Format, :JsonPointerFormat, :RelativeJsonPointerFormat, :UuidFormat, :UNKNOWN,
        :DATE, :TIME, :DATE_TIME, :DURATION, :IPV4, :IPV6, :JSON_POINTER, :RELATIVE_JSON_POINTER, :UUID
    end
  end

  private_constant :Internal
end
