:erlang.system_flag(:schedulers_online, 2)

defmodule Clustering do
  def join_cluster() do
    Node.start(:leader, :shortnames)
    Node.set_cookie(:my_cookie)
    Node.connect(:"drone1@devon-XPS-13-9370")
    Node.connect(:"drone2@devon-XPS-13-9370")
    Node.connect(:"drone3@devon-XPS-13-9370")
  end

  def copy_code_path() do
    path = :code.get_path()
    :rpc.multicall(Node.list(), :code, :set_path, [path])
  end
end

Clustering.join_cluster()
Clustering.copy_code_path()

Distributed.ExUnit.start()
