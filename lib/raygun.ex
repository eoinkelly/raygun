defmodule Raygun.Log.Error do
  defexception message: "default message"
end

defmodule Raygun.Plug do
  defmacro __using__(_env) do
    quote location: :keep do
      @before_compile Raygun.Plug
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep do
      defoverridable [call: 2]

      def call(conn, opts) do
        try do
          super(conn, opts)
        rescue
          exception ->
            stacktrace = System.stacktrace
            Raygun.report(stacktrace, exception, env: Atom.to_string(Mix.env))

            reraise exception, stacktrace
        end
      end
    end
  end
end

defmodule Raygun do
  use GenEvent

  @api_endpoint "https://api.raygun.io"

  # LOGGING SECTION
  def handle_call({:configure, _options}, state) do
    {:ok, :ok, state}
  end

  def handle_event({:error, gl, {Logger, msg, _ts, _md}}, state) when node(gl) == node() do
    IO.puts "we are going to send an error to Raygun, yeah!"
    if Exception.exception? msg do
      capture msg
    else
      report_message(msg)
    end
    {:ok, state}
  end

  def handle_event(data, state) do
    IO.puts "handling a logging event..."
    IO.inspect data
    {:ok, state}
  end

  # GENERAL CAPTURE SECTION

  def capture(exception, opts \\ %{}) do
    report(System.stacktrace, exception, opts)
  end

  def report_message(msg, opts \\ %{}) do
    %{
      occurredOn: now,
      details:
        details
        |> Dict.merge( environment )
        |> Dict.merge( user )
        |> Dict.merge( custom(opts) )
        |> Dict.merge( %{error: %{ message: msg } } )
    }
    |> Poison.encode!
    |> send_report
  end

  def report(stacktrace, exception, opts \\ %{}) do
    %{
      occurredOn: now,
      details:
        details
        |> Dict.merge( err(stacktrace, exception) )
        |> Dict.merge( environment )
        |> Dict.merge( user )
        |> Dict.merge( custom(opts) )
    }
    |> Poison.encode!
    |> send_report
  end

  def plug_report(conn, stacktrace, exception, opts \\ %{}) do
    %{
      occurredOn: now,
      details:
        details
        |> Dict.merge( err(stacktrace, exception) )
        |> Dict.merge( environment )
        |> Dict.merge( request(conn) )
        |> Dict.merge( response(conn) )
        |> Dict.merge( user(conn) )
        |> Dict.merge( custom(opts) )
    }
    |> Poison.encode!
    |> send_report
  end

  def send_report(json) do
    headers = %{
      "Content-Type": "application/json; charset=utf-8",
      "Accept": "application/json",
      "User-Agent": "Elixir Client",
      "X-ApiKey": Application.get_env(:raygun, :api_key)
    }
    {:ok, response} = HTTPoison.post(@api_endpoint <> "/entries", json, headers)
    %HTTPoison.Response{status_code: 202} = response
  end

  def custom(opts) do
    %{
      tags: Application.get_env(:raygun,:tags),
		  userCustomData: opts
    }
  end

  def user() do
    %{user: Application.get_env(:raygun, :system_user)}
  end

  def user(_conn) do
    %{user: %{
  			identifier: "",
  			isAnonymous: true,
  			email: "",
  			fullName: "",
  			firstName: "",
  			uuid: ""
		  }
    }
  end

  def environment do
    :disksup.start_link
    disks = :disksup.get_disk_data
    disk_free_spaces = for {_mount_point, capacity, percent_used} <- disks do
      ((100-percent_used)/100) * capacity
    end

    {:ok, hostname} = :inet.gethostname
    hostname = hostname |> List.to_string
    {os_type, os_flavor} = :os.type
    os_version = "#{os_type} - #{os_flavor}"
    architecture = :erlang.system_info(:system_architecture) |> List.to_string
    sys_version = :erlang.system_info(:system_version) |> List.to_string
    processor_count = :erlang.system_info(:logical_processors_online)
    memory_used = :erlang.memory(:total)
    %{environment: %{
        osVersion: os_version,
        architecture: architecture,
        packageVersion: sys_version,
        processorCount: processor_count,
        totalPhysicalMemory: memory_used,
        deviceName: hostname,
        diskSpaceFree: disk_free_spaces,
      }
    }
  end

  def details do
    {:ok, hostname} = :inet.gethostname
    hostname = hostname |> List.to_string

    %{
    		machineName: hostname,
    		version: Mix.Project.config[:deps][:poison],
    		client: %{
    			name: Mix.Project.config[:app],
    			version: Mix.Project.config[:version],
    			clientUrl: Mix.Project.config[:raygun][:url]
    		}
    }
  end

  def now do
    {:ok, datetime} = Timex.Date.now |> Timex.DateFormat.format("{ISOz}")
    datetime
  end

  def request(conn) do
    %{request: %{
        hostName: conn.host,
        url: Atom.to_string(conn.scheme) <> "://" <> conn.host <> ":" <> conn.port <> conn.request_path,
        httpMethod: conn.method,
        iPAddress: conn.remote_ip,
        queryString: Plug.Conn.fetch_query_params(conn),
        form: Plug.Parsers.call(conn).params,
        headers: conn.req_headers,
        rawData: %{}
      }
    }
  end

  def response(conn) do
    %{response: %{
        statusCode: conn.status
      }
    }
  end

  def err(stacktrace, error) do
    s0 = Enum.at(stacktrace, 0) |> stacktrace_entry
    %{error: %{
        innerError: nil,
        data: %{fileName: s0.fileName, lineNumber: s0.lineNumber, function: s0.methodName},
        className: s0.className,
        message: Exception.message(error),
        stackTrace: stacktrace(stacktrace)
      }
    }
  end

  def stacktrace(s) do
    s |> Enum.map(&stacktrace_entry/1)
  end

  def stacktrace_entry(entry = {module, function, arity_or_args, location}) do
    IO.inspect entry
    %{
      lineNumber: line_from(location),
      className: mod_for(module),
      fileName: file_from(location),
      methodName: fa(function,arity_or_args)
    }
  end
  def stacktrace_entry({function, arity_or_args, location}) do
    stacktrace_entry {__MODULE__, function, arity_or_args, location}
  end

  def fa(function,arity) do
    "#{Atom.to_string(function)}/#{arity}"
  end

  def mod_for(module) when is_atom(module) do
    Atom.to_string(module)
  end
  def mod_for(module) when is_binary(module) do
    module
  end

  def line_from(file: _file, line: line) do
    line
  end

  def file_from(file: file, line: _line) do
    file |> List.to_string
  end

end
