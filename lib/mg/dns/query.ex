defmodule Mg.DNS.Query do
  @moduledoc """
  DNS Query records <-> struct functions
  """

  record = Record.extract(:dns_query, from_lib: "kernel/src/inet_dns.hrl")
  keys = :lists.map(&elem(&1, 0), record)
  vals = :lists.map(&{&1, [], nil}, keys)
  pairs = :lists.zip(keys, vals)

  defstruct record
  @type t :: %__MODULE__{}

  @doc """
  Converts a `DNS.Query` struct to a `:dns_query` record.
  """
  def to_record(%Mg.DNS.Query{unquote_splicing(pairs)}) do
    {:dns_query, unquote_splicing(vals)}
  end

  @doc """
  Converts a `:dns_query` record into a `DNS.Query`.
  """
  def from_record(file_info)

  def from_record({:dns_query, unquote_splicing(vals)}) do
    %Mg.DNS.Query{unquote_splicing(pairs)}
  end
end
