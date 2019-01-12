type t = int
type span = int

let compare t1 t2 = t1 - t2

let diff t1 t2 = abs (t1 - t2)

let inc t s = t + s

let span_of_int i = if i < 0 then assert(false) else i

let t_of_int i = if i < 0 then assert(false) else i
