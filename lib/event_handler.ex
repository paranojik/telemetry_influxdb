defmodule TelemetryInfluxDB.EventHandler do
  @moduledoc false

  use GenServer

  alias TelemetryInfluxDB, as: InfluxDB
  alias TelemetryInfluxDB.BatchReporter
  alias TelemetryInfluxDB.Formatter

  @spec start_link(InfluxDB.config()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)
    config = config.publisher.add_config(config)
    handler_ids = attach_events(config.events, config)

    {:ok, %{handler_ids: handler_ids}}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  @spec attach_events([InfluxDB.event_spec()], InfluxDB.config()) :: [InfluxDB.handler_id()]
  defp attach_events(event_specs, config) do
    Enum.map(event_specs, &attach_event(&1, config))
  end

  @spec attach_event(InfluxDB.event_spec(), InfluxDB.config()) :: InfluxDB.handler_id()
  defp attach_event(event_spec, config) do
    telemetry_config =
      config
      |> Map.delete(:events)
      |> Map.put(:metadata_tag_keys, event_spec[:metadata_tag_keys] || [])
      |> Map.put(:tag_values, event_spec[:tag_values] || & &1)

    handler_id = handler_id(event_spec.name, config.reporter_name)

    :ok =
      :telemetry.attach(handler_id, event_spec.name, &__MODULE__.handle_event/4, telemetry_config)

    handler_id
  end

  @spec handle_event(
          InfluxDB.event_name(),
          InfluxDB.event_measurements(),
          InfluxDB.event_metadata(),
          InfluxDB.config()
        ) :: :ok
  def handle_event(event, measurements, metadata, config) do
    event_tags = Map.get(metadata, :tags, %{})
    event_metadatas = extract_tags(config, metadata)

    tags =
      Map.merge(config.tags, event_tags)
      |> Map.merge(event_metadatas)

    formatted_event = Formatter.format(event, measurements, tags)

    BatchReporter.get_name(config)
    |> BatchReporter.enqueue_event({formatted_event, config})

    :ok
  end

  defp extract_tags(config, metadata) do
    tag_values = config.tag_values.(metadata)
    Map.take(tag_values, config.metadata_tag_keys)
  end

  @spec handler_id(InfluxDB.event_name(), binary()) :: InfluxDB.handler_id()
  defp handler_id(event_name, prefix) do
    {__MODULE__, event_name, prefix}
  end

  @impl GenServer
  def terminate(_reason, state) do
    for handler_id <- state.handler_ids do
      :telemetry.detach(handler_id)
    end

    :ok
  end
end
