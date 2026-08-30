# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "JsonSchemaValidator::Internal::Formats" do
  def formats
    JsonSchemaValidator.const_get(:Internal).const_get(:Formats)
  end

  def expect_cases(format, cases)
    format = formats.resolve(format)
    cases.each do |value, expected|
      expect(formats.valid?(format, value)).to eq(expected), -> { "expected #{value.inspect} to be #{expected ? "valid" : "invalid"}" }
    end
  end

  describe "date" do
    let(:calendar_boundaries) do
      {
        "1963-06-19" => true,
        "2020-01-31" => true,
        "2020-04-30" => true,
        "2020-02-29" => true,
        "0400-02-29" => true,
        "2021-02-28" => true
      }
    end

    let(:invalid_month_days) do
      {
        "2020-01-00" => false,
        "2020-01-32" => false,
        "2020-04-31" => false,
        "2020-02-30" => false,
        "2021-02-29" => false,
        "0100-02-29" => false,
        "2100-02-29" => false
      }
    end

    let(:invalid_date_grammar) do
      {
        "1998-00-01" => false,
        "1998-13-01" => false,
        "1998-1-20" => false,
        "1998-01-1" => false,
        "+11963-06-19" => false,
        "20230328" => false,
        "1963-06-1৪" => false,
        " 2024-01-15" => false,
        "2024-01-15\n" => false,
        "2020-01-01\0" => false
      }
    end

    it("accepts calendar boundaries", :aggregate_failures) { expect_cases("date", calendar_boundaries) }
    it("rejects days outside their month", :aggregate_failures) { expect_cases("date", invalid_month_days) }
    it("rejects values outside the RFC 3339 grammar", :aggregate_failures) { expect_cases("date", invalid_date_grammar) }
  end

  describe "time" do
    let(:valid_offsets) do
      {
        "08:30:06Z" => true,
        "08:30:06z" => true,
        "23:20:50.52Z" => true,
        "00:59:59.999999999999999Z" => true,
        "08:30:06+00:20" => true,
        "08:30:06-08:00" => true,
        "12:34:56-00:00" => true,
        "00:00:00+23:59" => true
      }
    end

    let(:leap_seconds) do
      {
        "23:59:60Z" => true,
        "23:59:60+00:00" => true,
        "01:29:60+01:30" => true,
        "23:29:60+23:30" => true,
        "15:59:60-08:00" => true,
        "00:29:60-23:30" => true,
        "22:59:60Z" => false,
        "23:58:60Z" => false,
        "23:59:60+01:00" => false,
        "23:59:60-00:30" => false
      }
    end

    let(:out_of_range_times) do
      {
        "24:00:00Z" => false,
        "00:60:00Z" => false,
        "00:00:61Z" => false,
        "01:02:03+24:00" => false,
        "01:02:03+00:60" => false
      }
    end

    let(:malformed_times) do
      {
        "8:30:06Z" => false,
        "08:3:06Z" => false,
        "08:30:6Z" => false,
        "08:30:06" => false,
        "08:30:06.Z" => false,
        "08:30:06,5Z" => false,
        "08:30:06+0130" => false,
        "08:30:06+01" => false,
        "08:30:06Z+00:30" => false,
        "1২:00:00Z" => false,
        "08:30:06Z\n" => false
      }
    end

    it("accepts UTC and numeric offsets", :aggregate_failures) { expect_cases("time", valid_offsets) }
    it("accepts leap seconds only at the UTC end of day", :aggregate_failures) { expect_cases("time", leap_seconds) }
    it("rejects out-of-range components", :aggregate_failures) { expect_cases("time", out_of_range_times) }
    it("rejects malformed lexical components", :aggregate_failures) { expect_cases("time", malformed_times) }
  end

  describe "date-time" do
    let(:valid_date_times) do
      {
        "1963-06-19T08:30:06Z" => true,
        "1963-06-19t08:30:06z" => true,
        "1937-01-01T12:00:27.87+00:20" => true,
        "1998-12-31T15:59:60.123-08:00" => true,
        "2020-02-29T00:00:00Z" => true
      }
    end

    let(:invalid_date_time_components) do
      {
        "2021-02-29T00:00:00Z" => false,
        "1990-12-31T24:00:00Z" => false,
        "1990-12-31T15:60:00Z" => false,
        "1990-12-31T10:00:00+10:60" => false,
        "1998-12-31T23:58:60Z" => false
      }
    end

    let(:invalid_date_time_grammar) do
      {
        "1963-06-19 08:30:06Z" => false,
        "1963-6-19T08:30:06Z" => false,
        "1985-04-12T23:20Z" => false,
        "1985-04-12T23:20:50" => false,
        "1985-04-12T23:20:50Ztail" => false,
        "+11963-06-19T08:30:06Z" => false,
        "1985-04-12T23:20:50Z\n" => false
      }
    end

    it("combines valid date and time forms", :aggregate_failures) { expect_cases("date-time", valid_date_times) }
    it("rejects an invalid date or time component", :aggregate_failures) { expect_cases("date-time", invalid_date_time_components) }
    it("requires the complete date-time grammar", :aggregate_failures) { expect_cases("date-time", invalid_date_time_grammar) }
  end

  describe "duration" do
    let(:duration_cases) do
      {
        "P4Y" => true, "P1Y2M3DT4H5M6S" => true, "PT36H" => true,
        "P2W" => true, "P01D" => true, "P" => false, "PT" => false,
        "PT1D" => false, "P1Y2D" => false, "PT1H2S" => false,
        "P1WT1H" => false, "PT0.5S" => false
      }
    end

    it("implements the RFC 3339 duration grammar", :aggregate_failures) { expect_cases("duration", duration_cases) }
  end

  describe "uuid" do
    let(:uuid_cases) do
      {
        "2eb8aa08-aa98-11ea-b4aa-73b441d16380" => true,
        "2EB8AA08-AA98-11EA-B4AA-73B441D16380" => true,
        "00000000-0000-0000-0000-000000000000" => true,
        "2eb8aa08-aa98-11ea-b4ga-73b441d16380" => false,
        "2eb8aa08aa9811eab4aa73b441d16380" => false,
        "urn:uuid:2eb8aa08-aa98-11ea-b4aa-73b441d16380" => false
      }
    end

    it("accepts the canonical hexadecimal representation", :aggregate_failures) { expect_cases("uuid", uuid_cases) }
  end

  describe "json-pointer" do
    let(:json_pointer_cases) do
      {
        "" => true, "/foo//bar/~0~1" => true, "/foo/😎" => true,
        "/foo\0bar\n" => true, "foo/bar" => false, "#/foo" => false,
        "/foo/~2" => false, "/foo/~" => false
      }
    end

    it("validates pointer starts and tilde escapes", :aggregate_failures) { expect_cases("json-pointer", json_pointer_cases) }
  end

  describe "relative-json-pointer" do
    let(:relative_json_pointer_cases) do
      {
        "1" => true, "0/foo/bar" => true, "120/foo//bar" => true,
        "0#" => true, "" => false, "01/a" => false, "+1/a" => false,
        "0##" => false, "1#/foo" => false, "0/~2" => false
      }
    end

    it("validates the non-negative prefix and pointer suffix", :aggregate_failures) do
      expect_cases("relative-json-pointer", relative_json_pointer_cases)
    end
  end

  describe "dispatch" do
    it "preserves supported IPv4 and unknown-format behavior", :aggregate_failures do
      ipv4 = formats.resolve("ipv4")
      expect(formats.valid?(ipv4, "192.0.2.1")).to be(true)
      expect(formats.valid?(ipv4, "999.0.2.1")).to be(false)
      expect(formats.valid?(formats.resolve("unknown"), "anything")).to be(true)
    end

    it "resolves each format to a singleton descriptor", :aggregate_failures do
      expect(formats.resolve("date")).to equal(formats.resolve("date"))
      expect(formats.resolve("uuid")).to equal(formats.resolve("uuid"))
      expect(formats.resolve("unknown-a")).to equal(formats.resolve("unknown-b"))
    end
  end
end
