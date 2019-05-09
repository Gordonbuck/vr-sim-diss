open Core
open Yojson.Basic.Util
open VR
open VR_Params

exception Malformed_config

let parse_version version = 
  let optimisation = version |> member "optimisation" |> to_string in
  if optimisation = "base" then
    Base
  else if optimisation = "fast_reads" then
    let params = version |> member "params" |> to_float in
    FastReads(params)
  else
    raise Malformed_config

let parse_discrete_dist dist = 
  let distribution = dist |> member "distribution" |> to_string in
  if distribution = "bernoulli" then
    let params = dist |> member "params" |> to_float in
    Bernoulli(params)
  else if distribution = "gilbert_elliott" then
    let params = dist |> member "params" |> to_list |> filter_float in
    match params with
    | [p;r;k;h] -> GilbertElliott(p, r, k, h)
    | _ -> raise Malformed_config
  else
    raise Malformed_config

let parse_continuous_dist dist = 
  let distribution = dist |> member "distribution" |> to_string in
  if distribution = "constant" then
    let params = dist |> member "params" |> to_float in
    Constant(params)
  else if distribution = "uniform" then
    let params = dist |> member "params" |> to_list |> filter_float in
    match params with 
    | [l;h] -> Uniform(l,h)
    | _ -> raise Malformed_config
  else if distribution = "normal" then
    let params = dist |> member "params" |> to_list |> filter_float in
    match params with
    | [mu;stdv] -> Normal(mu,stdv)
    | _ -> raise Malformed_config
  else if distribution = "truncated_normal" then
    let params = dist |> member "params" |> to_list |> filter_float in
    match params with
    | [mu;stdv;lower] -> TruncatedNormal(mu,stdv,lower)
    | _ -> raise Malformed_config
  else
    raise Malformed_config

let parse_termination termination = 
  let term_type = termination |> member "type" |> to_string in
  if term_type = "work_completion" then
    WorkCompletion
  else if term_type = "time_limit" then
    let params = termination |> member "params" |> to_float in
    Timelimit(params)
  else
    raise Malformed_config

let parse_trace_level trace_level = 
  let trace_level = trace_level |> to_string in
  if trace_level = "high" then
    High
  else if trace_level = "medium" then 
    Medium
  else if trace_level = "low" then
    Low
  else
    raise Malformed_config

let json = Yojson.Basic.from_file "src/config.json"

let version = parse_version (json |> member "version")

let conf = 
  let n_replicas = json |> member "n_replicas" |> to_int in
  let n_clients = json |> member "n_clients" |> to_int in
  let max_replica_failures = json |> member "max_replica_failures" |> to_int in
  let max_client_failures = json |> member "max_client_failures" |> to_int in
  let n_iterations = json |> member "n_iterations" |> to_int in
  let workloads = 
    let workloads = json |> member "workloads" |> to_list |> filter_int in
    if (List.length workloads) <> n_clients then raise Malformed_config else workloads in

  let packet_loss = parse_discrete_dist (json |> member "packet_loss") in
  let packet_duplication = parse_discrete_dist (json |> member "packet_duplication") in
  let packet_delay = parse_continuous_dist (json |> member "packet_delay") in
  
  let heartbeat_timeout = json |> member "heartbeat_timeout" |> to_float in
  let prepare_timeout = json |> member "prepare_timeout" |> to_float in
  let primary_timeout = json |> member "primary_timeout" |> to_float in
  let statetransfer_timeout = json |> member "statetransfer_timeout" |> to_float in
  let startviewchange_timeout = json |> member "startviewchange_timeout" |> to_float in
  let doviewchange_timeout = json |> member "doviewchange_timeout" |> to_float in
  let recovery_timeout = json |> member "recovery_timeout" |> to_float in
  let getstate_timeout = json |> member "getstate_timeout" |> to_float in
  let request_timeout = json |> member "request_timeout" |> to_float in
  let clientrecovery_timeout = json |> member "clientrecovery_timeout" |> to_float in

  let clock_skew = parse_continuous_dist (json |> member "clock_skew") in

  let replica_failure = json |> member "replica_failure" in
  let replica_failure_period = replica_failure |> member "period" |> to_float in
  let replica_failure = (parse_discrete_dist replica_failure, 
                         parse_continuous_dist (replica_failure |> member "failure_time"),
                         parse_continuous_dist (replica_failure |> member "recover_time")
                        ) in
  
  let client_failure = json |> member "client_failure" in
  let client_failure_period = client_failure |> member "period" |> to_float in
  let client_failure = (parse_discrete_dist client_failure, 
                         parse_continuous_dist (client_failure |> member "failure_time"),
                         parse_continuous_dist (client_failure |> member "recover_time")
                        ) in
  
  let termination = parse_termination (json |> member "termination") in
  let trace_level = parse_trace_level (json |> member "trace_level") in
  let show_trace = json |> member "show_trace" |> to_bool in

  {
    n_replicas = n_replicas;
    n_clients = n_clients;
    max_replica_failures = max_replica_failures;
    max_client_failures = max_client_failures;
    n_iterations = n_iterations;
    workloads = workloads;
    packet_loss = packet_loss;
    packet_duplication = packet_duplication;
    packet_delay = packet_delay;
    heartbeat_timeout = heartbeat_timeout;
    prepare_timeout = prepare_timeout;
    primary_timeout = primary_timeout;
    statetransfer_timeout = statetransfer_timeout;
    startviewchange_timeout = startviewchange_timeout;
    doviewchange_timeout = doviewchange_timeout;
    recovery_timeout = recovery_timeout;
    getstate_timeout = getstate_timeout;
    request_timeout = request_timeout;
    clientrecovery_timeout = clientrecovery_timeout;
    clock_skew = clock_skew;
    replica_failure_period = replica_failure_period;
    replica_failure = replica_failure;
    client_failure_period = client_failure_period;
    client_failure = client_failure;
    termination = termination;
    trace_level = trace_level;
    show_trace = show_trace;
  }
  