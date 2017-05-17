defmodule Mg.Net.Block do
  require Record
  alias Mg.Net.Pool

  Record.defrecord :block, [id: nil, pool: nil, status: :free]

  @type id :: {:inet.ip_address, integer}
  @type status :: :free | :partial | :lease | :reserved
  @type t :: Record.record(:block, [id: id, pool: Pool.id, status: status])
end