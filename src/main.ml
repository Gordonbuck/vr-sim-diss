open Core
open Simulator
open VR_Params
open VR

let conf = {
  n_replicas = 11;
  n_clients = 20;
  max_replica_failures = 5;
  max_client_failures = 1;
  n_iterations = 1;
  workloads = (List.init 20 (fun _ -> 5));
  packet_loss = Bernoulli(0.1);
  packet_duplication = Bernoulli(0.1);
  packet_delay = TruncatedNormal(285.0, 350.0, 200.0);
  heartbeat_timeout = 1500.;
  prepare_timeout = 1200.0;
  primary_timeout = 3000.;
  statetransfer_timeout = 3000.;
  startviewchange_timeout = 1600.0;
  doviewchange_timeout = 1600.0;
  recovery_timeout = 1600.0;
  getstate_timeout = 1600.0;
  request_timeout = 3500.0;
  clientrecovery_timeout = 1600.0;
  clock_skew = Constant(0.);
  replica_failure_period = 60000000.;
  replica_failure = (Bernoulli(0.05), Uniform(0., 60000000.), TruncatedNormal(30000000., 5000000., 25000000.));
  client_failure_period = 60000000.;
  client_failure = (Bernoulli(0.05), Uniform(0., 60000000.), TruncatedNormal(30000000., 5000000., 25000000.));
  termination = WorkCompletion;
  trace_level = Medium;
  show_trace = true;
}

module MyParams = (val (build_params conf) : Params)

module MyVR = (val (build_protocol (Base)) : Protocol)

let sim_runs () = 
  let params_n = 19 in
  let n_iterations = 10000 in
  let module VR_Sim = Simulator(MyVR)(MyParams) in
  let rec run i =
    if i = n_iterations then ()
    else
      let newstdout = Out_channel.create (Printf.sprintf "data/params%i/trace_%i" params_n i) in
      Unix.dup2 (Unix.descr_of_out_channel newstdout) Unix.stdout;
      VR_Sim.run ();
      Out_channel.close newstdout;
      run (i+1) in
  run 0

let main () =
  let module VR_Sim = Simulator(MyVR)(MyParams) in
  VR_Sim.run ()

let using_parser () = 
  let module MyParams = (val (build_params Parser.conf) : Params) in
  let module MyVR = (val (build_protocol Parser.version) : Protocol) in
  let module VR_Sim = Simulator(MyVR)(MyParams) in
  VR_Sim.run ()

let () = using_parser ()
