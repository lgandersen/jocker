defmodule EngineUtilsTest do
  use ExUnit.Case
  alias Jocker.Engine.Utils

  @moduletag :capture_log

  test "decode buffer" do
    term = {:term, "this is in erlang term"}
    bin = :erlang.term_to_binary(term)
    part1 = String.slice(bin, 0, 10)
    assert {^term, ""} = Utils.decode_buffer(bin)
    assert {:no_full_msg, ^part1} = Utils.decode_buffer(part1)
    assert {^term, "moredata"} = Utils.decode_buffer(bin <> "moredata")
  end

  test "test duration_to_human_string(now, from)" do
    assert "Less than a second" == Utils.duration_to_human_string(10, 10)
    assert "1 second" == Utils.duration_to_human_string(10, 9)
    assert "59 seconds" == Utils.duration_to_human_string(60, 1)
    assert "About a minute" == Utils.duration_to_human_string(61, 1)
    assert "10 minutes" == Utils.duration_to_human_string(60 * 10, 1)
    assert "About an hour" == Utils.duration_to_human_string(60 * 61, 1)
    hour = 60 * 60
    assert "47 hours" == Utils.duration_to_human_string(hour * 47, 1)
    assert "2 days" == Utils.duration_to_human_string(hour * 48, 1)
    assert "2 weeks" == Utils.duration_to_human_string(hour * 24 * 7 * 2, 1)
    assert "12 months" == Utils.duration_to_human_string(hour * 24 * 365, 1)
    assert "2 years" == Utils.duration_to_human_string(hour * 24 * 365 * 2, 1)
  end

  test "test human_duration(from_string)" do
    assert "Less than a second" == Utils.human_duration(DateTime.to_iso8601(DateTime.utc_now()))
  end
end
