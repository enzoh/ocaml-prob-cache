(** 
 * A cache for sequence oriented probability models 
 * The event type is polymorphic but depends on equality, order? semantics.
 * /// ?
 * Use [@@deriving eq, ord?] to easily support this with your own types.
 *
 * Suppose we observe a sequence of events e_0, e_1, e_2, e_3
 * We now want to now the likelihoods of future observations e_4, e_5 or 
 * P(e_4,e_5|e_0, e_1, e_2, e_3) 
 * 
 * More concrete:
   * If we observe RED | GREEN | GREEN | BLUE | RED | GREEN
   * then our universe is the following
   RED - > 2
   RED | GREEN -> 2
   GREEN -> 3
   GREEN | GREEN -> 1
   RED | GREEN | GREEN -> 1
   BLUE -> 1
   GREEN | BLUE -> 1
   GREEN | GREEN | BLUE -> 1
   RED | GREEN | GREEN | BLUE -> 1
   BLUE | RED -> 1
   BLUE | RED | GREEN - > 1
   RED | GREEN | GREEN | BLUE | RED | GREEN -> 1
   GREEN | GREEN | BLUE | RED | GREEN -> 1
   GREEN | GREEN | BLUE | RED -> 1
   GREEN | BLUE | RED -> 1

   Complexity Overview:

   1) Total number of sequences we have to update given a new sequence of length of L is O(L),
      A frequency count is maintained for each subsequence of which there are L of them.
   2) If we cache each sequence independently we would get E^L + E^(L-1) + E^(L-2) .. entries,
      eg. O(E^L) in the worst case (E is cardinality of the event type). Ideally we would 
      observe much less than that, but this is also not the most efficient 
      representation, either.

      We can at least a little more efficiently encode the data by using a graphical representation.
      For instance, the observation RED | GREEN | RED results in this graphical encoding:
        [(RED, 2, [(GREEN, 1, [(RED, 1, [])])]);
        (GREEN, 1, [(RED, 1, [])])]
      The benefit is the key for GREEN | RED and is composed of the KEY for GREEN, which saves space referencing GREEN directly.
      While the complexity doesn't theoretically change much, in practice this can be a big win.

   Issues:

    Problem 1:
 
      When we start up, how do we know what state we are in? 
    
    Solution: 
      
      Assume we don't, and use probability techniques to figure out what state we started in 
      as we observe data from the stream. In theory this could also support the notion of 
      time "shifting" and picking up on the offset without a drastic adjustment
      to the model weights.
 **)

open Prob_cache_common
module Float = CCFloat

(** Represents a single event- must be comparable and showable *)  
module type EVENT = sig type t [@@deriving ord, show] end

(** Represents a discrete sequence of events *)
module type SEQUENCE = 
sig
  module Event : EVENT
  type t [@@deriving ord]
  val is_empty : t -> bool
  val union: t -> t -> t
  val empty : t
  val of_list : Event.t list -> t
  val to_list : t -> Event.t list
end


(** A module type provided polymorphic sequence model caches *)
module type S =
sig
  (** The module type representing a discrete sequence *)
  module Sequence : SEQUENCE

  (** The module type representing one event in a sequence *)
  module Event : module type of Sequence.Event
  
  (** A sequence model cache *)
  type t
  
  val create : string -> t      
  (** Creates a new sequence model labeled by the given string *)

  val count : Sequence.t -> t -> int
  (** How many times a particular sequence was observed *)

  val observe : ?cnt:int -> Sequence.t -> t -> t
  (** Observe a sequence with a default count of 1. The returned model reflects the observation updates
   * while the original instance is not guaranteed to be current. *)

  val prob : ?cond:Sequence.t -> Sequence.t -> t -> float
  (** Probability of future sequence given an observed sequence. If a conditional sequence is not specified
   * then an absolute probability is returned instead *)

  val name : t -> string
  (** Gets the name of the given sequence model *)

end


module Make_for_sequence (Sequence:SEQUENCE) : S with module Sequence = Sequence =
struct
  module Sequence = Sequence
  module Event = Sequence.Event
  module Cache = CCMultiSet.Make(Sequence)
  module Int = CCInt

  type t = {name:string; cache : Cache.t}

  let create name = {name;cache=Cache.empty}

  let count (sequence:Sequence.t) (t:t) : int = Cache.count t.cache sequence

  let prob ?(cond=Sequence.empty) (sequence:Sequence.t) (t:t) =
   let cond_count = count cond t in
    (* (a) If the conditional sequence has NOT been observed then probability must be zero
     * (b) If the conditional (possibly empty) sequence has been observed then we normalize by its frequency count 
     *)
    if (cond_count = 0) then (Float.of_int 0) else
    let full_seq_count = count (Sequence.union cond sequence) t in
    (Float.of_int full_seq_count) /. (Float.of_int cond_count)
  
  let increment ?(cnt=1) (sequence:Sequence.t) (t:t) =
    {name = t.name; cache=Cache.add_mult t.cache sequence cnt}

  let observe ?(cnt=1) (sequence:Sequence.t) (t:t) =
    let seq_as_list = Sequence.to_list sequence in
    let (l, t) = List.fold_right 
      (fun e (l, t) -> (l@[e], increment ~cnt (Sequence.of_list l) t))
      seq_as_list
      ([], t) 
    in increment ~cnt (Sequence.of_list l) t

  let name t = t.name
end


module Make_sequence(Event:EVENT) =
struct
  module Event = Event
  type t = Event.t list [@@deriving ord]
  let of_list l = l
  let to_list l = l
  let union = CCList.append
  let empty = CCList.empty
  let is_empty t = empty = t
  
end

module Make(Event:EVENT) = Make_for_sequence(Make_sequence(Event))

   