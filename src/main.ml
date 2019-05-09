open Core
open Simulator
open VR_Params
open VR

let conf = {
  n_replicas = 11;
  n_clients = 3;
  max_replica_failures = 5;
  max_client_failures = 1;
  n_iterations = 1;
  workloads = [10;15;20];
  packet_loss = (*GilbertElliott(0.03, 0.4, 0.99, 0.1);*) Bernoulli(0.01);
  packet_duplication = Bernoulli(0.01);
  packet_delay = TruncatedNormal(30., 6., 15.);
  heartbeat_timeout = 20.;
  prepare_timeout = 40.;
  primary_timeout = 120.;
  statetransfer_timeout = 50.;
  startviewchange_timeout = 40.;
  doviewchange_timeout = 40.;
  recovery_timeout = 40.;
  getstate_timeout = 40.;
  request_timeout = 40.;
  clientrecovery_timeout = 40.;
  clock_skew = Constant(0.);
  replica_failure_period = 1000.;
  replica_failure = (Bernoulli(0.5), Uniform(0., 500.), TruncatedNormal(400., 20., 200.));
  client_failure_period = 1000.;
  client_failure = (Bernoulli(0.5), Uniform(0., 500.), TruncatedNormal(400., 20., 200.));
  termination = WorkCompletion;
  trace_level = High;
  show_trace = true;
}

module MyParams = (val (build_params conf) : Params)

module MyVR = (val (build_protocol (FastReads(80.))) : Protocol)

let sim_runs () = 
  let params_n = 1 in
  let n_iterations = 100 in
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
