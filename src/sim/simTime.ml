type t = float
type span = float

let compare t1 t2 = int_of_float (t1 -. t2)

let diff t1 t2 = abs_float (t1 -. t2)

let inc t s = t +. s

let span_of_float i = if i < 0. then assert(false) else i

let t_of_float i = if i < 0. then assert(false) else i

let float_of_t t = t
