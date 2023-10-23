defmodule TestInitialization do
  alias Kleened.Core.{ZFS, Layer, MetaData}
  alias Kleened.API.Schemas

  @creation_time "2023-09-14T21:21:57.990515Z"

  def create_test_base_image() do
    {dataset, snapshot} = test_base_dataset()
    info = ZFS.info(dataset)
    snapshot_info = ZFS.info(snapshot)

    # Check if the testing dataset + snapshot exists
    cond do
      info[:exists?] == false ->
        raise RuntimeError,
          message: "kleenes root zfs filesystem #{dataset} does not seem to exist. Exiting."

      snapshot_info[:exists?] == false ->
        ZFS.snapshot(snapshot)

      true ->
        :ok
    end

    # Create the ad-hoc base-image to use in testing
    base_layer = %Layer{
      id: "base",
      dataset: dataset,
      snapshot: snapshot,
      mountpoint: ""
    }

    base_image = test_image()
    MetaData.add_layer(base_layer)
    MetaData.add_image(base_image)
  end

  def test_base_dataset() do
    dataset = "zroot/kleene_basejail"
    snapshot = "#{dataset}@kleene"
    {dataset, snapshot}
  end

  def test_image() do
    %Schemas.Image{
      id: "base",
      layer_id: "base",
      name: "FreeBSD",
      tag: "testing",
      user: "root",
      created: @creation_time
    }
  end
end