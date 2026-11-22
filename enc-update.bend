import Base

# enc-update: NixOS updates for olimpo, delfos and xty, made only while each
# machine is idle, tested on each machine after its switch, and rolled back
# on a machine where the update broke something (the user, 2026-11-22:
# "a configuration that updates nixos for all my systems (delfos, xty,
# olimpo), but only does the update in idle times of the computer"; "I
# don't want to be building ghc every time I update automatically"; "tests
# that an update didn't break anything (specifically for xty), and a
# rollback if something did break").
#
# enc-update.nix is the shim: the config files this program reads, the
# timer, the PATH. All the decisions are here, and their laws below.
#
#   enc-update idle        is this machine idle now? (exit 0 yes, 1 no)
#   enc-update health      this machine's checks, one line each: ok|fail TAB name TAB detail
#   enc-update guard FILE  may a `nix build --dry-run` that printed FILE go on?
#                          (exit 0 yes, 1 no: it would build a forbidden derivation)
#   enc-update run         the builder's cycle (olimpo, from its timer)
#   enc-update run --now   the same, even if not idle or already done today
#   enc-update status      what the last cycle did
#
# The cycle, on the builder (olimpo), as root:
#   1. Only when olimpo is idle, and not already done in the last
#      `every.hours` hours.
#   2. A clone of enc at origin/master (the user's own pushed config), its
#      inputs updated: all at once, or, if that would build something
#      forbidden (GHC, a kernel, a browser: the cache doesn't have it yet),
#      one input at a time, keeping each update that builds nothing
#      forbidden. A lock already seen to break a machine is not tried again.
#   3. Every machine's system built (and the xty checks the flake has).
#   4. Each machine in turn (delfos, olimpo, xty), when that machine is idle:
#      its checks run before, it switches, its checks run after; a check
#      that passed before and fails after, or a unit that newly failed, is a
#      break: the machine switches back to the system it had, and no further
#      machine is updated with that lock. xty's own gates run first (its
#      backups, its live checks: deploy-xty's).
#   5. Every machine updated and well: the lock is committed in the clone,
#      and handed on as the config says (push none: only as the branch
#      enc-update of ~/src/enc; branch: the branch enc-update on GitHub;
#      master: GitHub's master, as a fast-forward).

# Text --------------------------------------------------------------------------

def keep.put(empty: Bool, h: String, r: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}:
      r
    case False{}:
      h <> r

# the non-empty parts
def nonempty(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      keep.put(String.is_empty(h), h, nonempty(t))

def words(s: String) -> List<&2, String>:
  nonempty(String.split(s, ' '))

def fields(s: String) -> List<&2, String>:
  String.split(s, '\t')

def trimmed(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      String.trim(h) <> trimmed(t)

def lines(s: String) -> List<&2, String>:
  nonempty(trimmed(String.lines(s)))

def unwords(xs: List<&2, String>) -> String:
  String.join(xs, " ")

def has(xs: List<&2, String>, +x: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(String.eq(h, x), has(t, x))

def len(xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      Nat.add(1n, len(t))

def first.or(xs: List<&2, String>, d: String) -> String:
  match xs:
    case Nil{}:
      d
    case h <> t:
      h

def digit.val(c: Char) -> Nat:
  U32.to_nat(U32.sub(Char.to_u32(c), 48))

def digits.go(cs: List<&2, Char>, +acc: Nat) -> Nat:
  match cs:
    case Nil{}:
      acc
    case +c <> t:
      digits.go(t, Bool.pick(Nat, Char.is_digit(c), Nat.add(Nat.mul(acc, 10n), digit.val(c)), acc))

# a number's digits (anything else skipped): "17" 17, "" 0
def num(s: String) -> Nat:
  digits.go(String.to_list(s), 0n)

def frac2(s: String) -> Nat:
  num(String.take(String.append(s, "00"), 2n))

def hund.of(parts: List<&2, String>) -> Nat:
  match parts:
    case Nil{}:
      0n
    case i <> Nil{}:
      Nat.mul(num(i), 100n)
    case i <> f <> t:
      Nat.add(Nat.mul(num(i), 100n), frac2(f))

# "1.25" as hundredths (125), as /proc/loadavg writes it
def hundredths(s: String) -> Nat:
  hund.of(String.split(s, '.'))

def all.ver(cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(Bool.or(Char.is_digit(c), Char.is_eq(c, '.')), all.ver(t))

def ver.start(cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case +c <> t:
      Bool.and(Char.is_digit(c), all.ver(c <> t))

# a version and nothing else: "9.10.3", not "9.10.3-with-packages" nor ""
def version.only(s: String) -> Bool:
  ver.start(String.to_list(s))

# Being idle ----------------------------------------------------------------------

# what enc-update idle reads off the machine: the 5-minute load in
# hundredths, the seconds since a person last typed or moved the mouse, on
# mains power or not, the local hour, and whether a switch is running
type Facts is Data:
  Facts{load5: Nat, idle_s: Nat, ac: Bool, hour: Nat, busy: Bool}

# the machine's limits: the load at most, the idle seconds at least, mains
# power needed or not, and the hours it may switch in, [from, to) (from > to
# wraps past midnight; from = to: any hour)
type Policy is Data:
  Policy{load_max: Nat, idle_min: Nat, need_ac: Bool, from: Nat, to: Nat}

def hour.cmp(c: Cmp, +h: Nat, +from: Nat, +to: Nat) -> Bool:
  match c:
    case LT{}:
      Bool.and(Nat.is_ge(h, from), Nat.is_lt(h, to))
    case EQ{}:
      True{}
    case GT{}:
      Bool.or(Nat.is_ge(h, from), Nat.is_lt(h, to))

def hour.in(+h: Nat, +from: Nat, +to: Nat) -> Bool:
  hour.cmp(Nat.cmp(from, to), h, from, to)

def why.if(bad: Bool, w: String, rest: List<&2, String>) -> List<&2, String>:
  match bad:
    case True{}:
      w <> rest
    case False{}:
      rest

# why this machine is not idle; none: it is
def idle.why(p: Policy, f: Facts) -> List<&2, String>:
  match p f:
    case Policy{+lmax, +imin, need, +from, +to} Facts{+l, +i, ac, +h, busy}:
      why.if(Nat.is_gt(l, lmax), "load " ++ Nat.show(l) ++ "/100 is above " ++ Nat.show(lmax) ++ "/100",
      why.if(Nat.is_lt(i, imin), "used " ++ Nat.show(i) ++ " s ago (idle needs " ++ Nat.show(imin) ++ " s)",
      why.if(Bool.and(need, Bool.not(ac)), "on battery",
      why.if(Bool.not(hour.in(h, from, to)), "hour " ++ Nat.show(h) ++ " is outside " ++ Nat.show(from) ++ "-" ++ Nat.show(to),
      why.if(busy, "a switch or a rebuild is running", Nil{})))))

# The build guard --------------------------------------------------------------------

# a derivation's name: /nix/store/HASH-ghc-9.10.3.drv is ghc-9.10.3
def drv.name(+p: String) -> String:
  +n = String.drop(p, 44n)
  Bool.pick(String, String.ends_with(n, ".drv"), String.take(n, Nat.sub(String.length(n), 4n)), n)

# f's own build: f, or f-VERSION (ghc-9.10.3; not ghc-paths-0.1.0.12, a
# library, nor ghc-9.10.3-with-packages, a link farm, nor ghc-binary-9.8.4,
# a fetched binary)
def forbidden.one(+f: String, +n: String) -> Bool:
  Bool.or(String.eq(n, f), Bool.and(String.starts_with(n, f ++ "-"), version.only(String.drop(n, Nat.add(String.length(f), 1n)))))

def forbidden(fs: List<&2, String>, +n: String) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case f <> t:
      Bool.or(forbidden.one(f, n), forbidden(t, n))

def is.drv(+l: String) -> Bool:
  Bool.and(String.starts_with(l, "/nix/store/"), String.ends_with(l, ".drv"))

# what a dry run would build: its lines that are a .drv (what it would fetch
# are store paths, no .drv)
def to.build(ls: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      keep.put(Bool.not(is.drv(l)), drv.name(l), to.build(t))

def bad.of(+fs: List<&2, String>, ns: List<&2, String>) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      keep.put(Bool.not(forbidden(fs, n)), n, bad.of(fs, t))

# the forbidden derivations a dry run's output would build; none: go on
def guard(+fs: List<&2, String>, out: String) -> List<&2, String>:
  bad.of(fs, to.build(lines(out)))

# Health -------------------------------------------------------------------------------

# one check's answer on one machine
type Check is Data:
  Check{ok: Bool, name: String, detail: String}

def check.line(c: Check) -> String:
  match c:
    case Check{ok, n, d}:
      Bool.pick(String, ok, "ok", "fail") ++ "\t" ++ n ++ "\t" ++ d

def check.of.go(fs: List<&2, String>) -> Maybe<&2, Check>:
  match fs:
    case "ok" <> n <> d:
      Some{Check{True{}, n, String.join(d, " ")}}
    case "fail" <> n <> d:
      Some{Check{False{}, n, String.join(d, " ")}}
    case _:
      None{}

def check.of(+l: String) -> Maybe<&2, Check>:
  check.of.go(fields(l))

def checks.put(m: Maybe<&2, Check>, r: List<&2, Check>) -> List<&2, Check>:
  match m:
    case Some{c}:
      c <> r
    case None{}:
      r

# enc-update health's lines, read back (other lines skipped)
def checks.of(ls: List<&2, String>) -> List<&2, Check>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      checks.put(check.of(l), checks.of(t))

def failing(xs: List<&2, Check>, +n: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Check{ok, +m, d} <> t:
      Bool.or(Bool.and(Bool.not(ok), String.eq(m, n)), failing(t, n))

def broke.put(bad: Bool, +c: Check, r: List<&2, String>) -> List<&2, String>:
  match bad:
    case True{}:
      check.line(c) <> r
    case False{}:
      r

# what an update broke: each check failing after that was not failing
# before (one that passed, or a unit failed that had not, or a check the new
# system added that fails)
def broke(+before: List<&2, Check>, after: List<&2, Check>) -> List<&2, String>:
  match after:
    case Nil{}:
      Nil{}
    case +c <> t:
      match c:
        case Check{ok, +n, d}:
          broke.put(Bool.and(Bool.not(ok), Bool.not(failing(before, n))), c, broke(before, t))

# The laws, checked by the build ------------------------------------------------------------

def p.desk() -> Policy:
  Policy{400n, 1800n, False{}, 0n, 0n}

def p.xty() -> Policy:
  Policy{100n, 1800n, False{}, 3n, 6n}

law idle_when_quiet:
  {idle.why(p.desk(), Facts{120n, 3600n, True{}, 14n, False{}}) == [] : List<&2, String>}

def idle_when_quiet():
  {==}

law busy_when_typing:
  {len(idle.why(p.desk(), Facts{120n, 30n, True{}, 14n, False{}})) == 1n : Nat}

def busy_when_typing():
  {==}

law busy_when_loaded:
  {len(idle.why(p.desk(), Facts{650n, 3600n, True{}, 14n, False{}})) == 1n : Nat}

def busy_when_loaded():
  {==}

law busy_while_switching:
  {len(idle.why(p.desk(), Facts{0n, 9999n, True{}, 14n, True{}})) == 1n : Nat}

def busy_while_switching():
  {==}

law laptop_on_battery:
  {len(idle.why(Policy{200n, 1800n, True{}, 0n, 0n}, Facts{0n, 9999n, False{}, 3n, False{}})) == 1n : Nat}

def laptop_on_battery():
  {==}

law xty_in_its_hours:
  {idle.why(p.xty(), Facts{10n, 99999n, True{}, 4n, False{}}) == [] : List<&2, String>}

def xty_in_its_hours():
  {==}

law xty_not_at_noon:
  {len(idle.why(p.xty(), Facts{10n, 99999n, True{}, 12n, False{}})) == 1n : Nat}

def xty_not_at_noon():
  {==}

law hours_wrap_past_midnight:
  {hour.in(2n, 22n, 6n) == True{} : Bool}

def hours_wrap_past_midnight():
  {==}

law hours_wrap_not_noon:
  {hour.in(12n, 22n, 6n) == False{} : Bool}

def hours_wrap_not_noon():
  {==}

law load_reads:
  {hundredths("1.25") == 125n : Nat}

def load_reads():
  {==}

law load_reads_whole:
  {hundredths("3") == 300n : Nat}

def load_reads_whole():
  {==}

def forbid() -> List<&2, String>:
  ["ghc", "rustc", "linux"]

law ghc_is_refused:
  {guard(forbid(), "these 2 derivations will be built:\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-ghc-9.10.3.drv\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-hello-2.12.drv\n") == ["ghc-9.10.3"] : List<&2, String>}

def ghc_is_refused():
  {==}

law ghc_libraries_are_fine:
  {guard(forbid(), "  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-ghc-paths-0.1.0.12.drv\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-ghc-9.10.3-with-packages.drv\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-ghc-binary-9.8.4.drv\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-linux-pam-1.7.drv\n") == [] : List<&2, String>}

def ghc_libraries_are_fine():
  {==}

law fetching_is_fine:
  {guard(forbid(), "these 1 paths will be fetched (300 MiB download):\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-ghc-9.10.3\n") == [] : List<&2, String>}

def fetching_is_fine():
  {==}

law kernel_is_refused:
  {guard(forbid(), "  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-linux-6.18.60.drv\n") == ["linux-6.18.60"] : List<&2, String>}

def kernel_is_refused():
  {==}

# from the real dry run of nixpkgs 2786a2a (2026-11-21) for all three machines:
# the kernel comes from the cache; only its module tree and initrd are made
law nixpkgs_update_builds_nothing_forbidden:
  {guard(forbid(), "these 4 derivations will be built:\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-initrd-linux-6.18.64.drv\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-linux-6.18.64-modules-shrunk.drv\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-emacs-with-packages-31.1.drv\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-olimpo-26.11.drv\nthese 277 paths will be fetched (1.7 GiB download, 7.4 GiB unpacked):\n  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-linux-6.18.64\n") == [] : List<&2, String>}

def nixpkgs_update_builds_nothing_forbidden():
  {==}

law same_health_broke_nothing:
  {broke([Check{True{}, "unit nginx", "active"}, Check{False{}, "failed foo.service", ""}], [Check{True{}, "unit nginx", "active"}, Check{False{}, "failed foo.service", ""}]) == [] : List<&2, String>}

def same_health_broke_nothing():
  {==}

law a_stopped_service_is_a_break:
  {broke([Check{True{}, "unit nginx", "active"}], [Check{False{}, "unit nginx", "failed"}]) == ["fail\tunit nginx\tfailed"] : List<&2, String>}

def a_stopped_service_is_a_break():
  {==}

law a_newly_failed_unit_is_a_break:
  {broke([Check{False{}, "failed a.service", ""}], [Check{False{}, "failed a.service", ""}, Check{False{}, "failed b.service", ""}]) == ["fail\tfailed b.service\t"] : List<&2, String>}

def a_newly_failed_unit_is_a_break():
  {==}

law a_fixed_check_is_no_break:
  {broke([Check{False{}, "http docxty.net", "502"}], [Check{True{}, "http docxty.net", "200"}]) == [] : List<&2, String>}

def a_fixed_check_is_no_break():
  {==}

law health_lines_read_back:
  {checks.of(["ok\tunit nginx\tactive", "garbage", "fail\thttp x\t000"]) == [Check{True{}, "unit nginx", "active"}, Check{False{}, "http x", "000"}] : List<&2, Check>}

def health_lines_read_back():
  {==}

# Running programs ---------------------------------------------------------------------------

# a program's exit status and its output
type Ran is Data:
  Ran{code: U32, out: String}

# a program's exit status and its stdout and stderr together (127: it could
# not start, or it timed out)
def got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> Ran:
  match r:
    case Done{(code, (out, err))}:
      Ran{code, String.append(out, err)}
    case Fail{(code, msg)}:
      Ran{127, msg}

def got.out(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> Ran:
  match r:
    case Done{(code, (out, err))}:
      Ran{code, out}
    case Fail{(code, msg)}:
      Ran{127, ""}

def run.ms(prog: String, args: List<String>, ms: U32) -> IO(Ran):
  do IO<Ran>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, args, "", 67108864, ms)
    return got(r)

# a program's exit status and stdout only (for output to parse)
def run.out(prog: String, args: List<String>, ms: U32) -> IO(Ran):
  do IO<Ran>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, args, "", 67108864, ms)
    return got.out(r)

def run(prog: String, args: List<String>) -> IO(Ran):
  run.ms(prog, args, 600000)

# a reusable list of words as the arguments Process.run takes
def args.lin(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      h <> args.lin(t)

def ok.of(r: Ran) -> Bool:
  match r:
    case Ran{code, out}:
      U32.is_eq(code, 0)

def out.of(r: Ran) -> String:
  match r:
    case Ran{code, out}:
      String.trim(out)

def tail.of(r: Ran) -> String:
  match r:
    case Ran{code, out}:
      String.take(String.trim(out), 2000n)

def file.text.fin(p: File & Result<&1, &1, U32 & String, String>) -> IO(String):
  match p:
    case (f, Done{t}):
      do IO<String>:
        File.close(f)
        return t
    case (f, Fail{_}):
      do IO<String>:
        File.close(f)
        return ""

# a file's text ("" when it can't be read)
def file.text.go(r: Result<&1, &1, U32 & String, File>) -> IO(String):
  match r:
    case Done{f}:
      do IO<String>:
        p : File & Result<&1, &1, U32 & String, String> <- File.read(f, 16777216)
        file.text.fin(p)
    case Fail{_}:
      IO.pure(String, "")

def file.text(path: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    file.text.go(r)

def file.put.fin(p: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match p:
    case (f, w):
      File.close(f)

def file.put.go(r: Result<&1, &1, U32 & String, File>, text: String) -> IO(Unit):
  match r:
    case Done{f}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, text)
        file.put.fin(p)
    case Fail{_}:
      IO.pure(Unit, Unit{})

def file.put(path: String, text: String, mode: String) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, mode)
    file.put.go(r, text)

# The config (/etc/enc-update/config, written by enc-update.nix) ---------------------------------

# its lines KEY VALUE...: the first line with KEY, its value (all its words)
def conf.get.pick(hit: Bool, v: String, r: String) -> String:
  match hit:
    case True{}:
      v
    case False{}:
      r

# one line's words: its value if its key is k, else r (what the later lines give)
def conf.get.at(ws: List<&2, String>, +k: String, r: String) -> String:
  match ws:
    case +w <> vs:
      conf.get.pick(String.eq(w, k), unwords(vs), r)
    case Nil{}:
      r

def conf.get(ls: List<&2, String>, +k: String, d: String) -> String:
  match ls:
    case Nil{}:
      d
    case +l <> t:
      conf.get.at(words(l), k, conf.get(t, k, d))

# every line with KEY, its value
def conf.all.at(ws: List<&2, String>, +k: String, r: List<&2, String>) -> List<&2, String>:
  match ws:
    case +w <> vs:
      keep.put(Bool.not(String.eq(w, k)), unwords(vs), r)
    case Nil{}:
      r

def conf.all(ls: List<&2, String>, +k: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      conf.all.at(words(l), k, conf.all(t, k))

def env.or(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{_}:
      d

# the directory of the config and health files: /etc/enc-update, or
# $ENC_UPDATE_ETC (to try it by hand)
def etc() -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env("ENC_UPDATE_ETC")
    return env.or(r, "/etc/enc-update")

def conf() -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    e : String <- etc()
    t : String <- file.text(e ++ "/config")
    return lines(t)

def policy.of(+c: List<&2, String>) -> Policy:
  Policy{hundredths(conf.get(c, "load.max", "4")), Nat.mul(num(conf.get(c, "idle.minutes", "30")), 60n), String.eq(conf.get(c, "ac.required", "no"), "yes"), num(conf.get(c, "hours.from", "0")), num(conf.get(c, "hours.to", "0"))}

# enc-update idle --------------------------------------------------------------------------------------

def max.of(xs: List<&2, String>, m: Nat) -> Nat:
  match xs:
    case Nil{}:
      m
    case x <> t:
      max.of(t, Nat.max(num(x), m))

# each line's whole seconds (what comes before its first dot)
def secs.of(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      first.or(String.split(x, '.'), "0") <> secs.of(t)

# the seconds since the last keystroke on any terminal: now less the latest
# access of /dev/pts/N and /dev/ttyN (as w shows them; no terminal: a day)
def tty.idle(+now: Nat) -> IO(Nat):
  do IO<Nat>:
    +r : Ran <- run.out("find", ["/dev/pts", "/dev", "-maxdepth", "1", "(", "-name", "[0-9]*", "-o", "-name", "tty[0-9]*", ")", "-printf", "%A@\n"], 20000)
    +last : Nat = max.of(secs.of(trimmed(lines(out.of(r)))), 0n)
    return Bool.pick(Nat, Nat.is_eq(last, 0n), 86400n, Nat.sub(now, last))

def x.idle.of(r: Ran) -> Nat:
  match r:
    case Ran{code, out}:
      Bool.pick(Nat, U32.is_eq(code, 0), Nat.div(num(String.trim(out)), 1000n), 86400n)

# the seconds since the X screen last had a key or the mouse (no X: a day)
def x.idle(+c: List<&2, String>) -> IO(Nat):
  do IO<Nat>:
    +r : Ran <- run.out("env", ["DISPLAY=" ++ conf.get(c, "x.display", ":0"), "XAUTHORITY=" ++ conf.get(c, "x.authority", "/run/user/1000/gdm/Xauthority"), "xprintidle"], 10000)
    return x.idle.of(r)

def ac.of(+t: String, +online: String) -> Bool:
  Bool.or(Bool.not(String.eq(String.trim(t), "Mains")), String.eq(String.trim(online), "1"))

# on mains power: every Mains supply in /sys/class/power_supply online (none:
# a desktop or a server, always on mains)
def ac.go(xs: List<&2, String>) -> IO(Bool):
  match xs:
    case Nil{}:
      IO.pure(Bool, True{})
    case +x <> t:
      do IO<Bool>:
        +ty : String <- file.text(x ++ "/type")
        +on : String <- file.text(x ++ "/online")
        rest : Bool <- ac.go(t)
        return Bool.and(ac.of(ty, on), rest)

def ac() -> IO(Bool):
  do IO<Bool>:
    +r : Ran <- run.out("find", ["/sys/class/power_supply/", "-mindepth", "1", "-maxdepth", "1"], 10000)
    ac.go(lines(out.of(r)))

def facts(+c: List<&2, String>) -> IO(Facts):
  do IO<Facts>:
    la : String <- file.text("/proc/loadavg")
    +n : Ran <- run.out("date", ["+%s"], 5000)
    +now : Nat = num(out.of(n))
    +h : Ran <- run.out("date", ["+%H"], 5000)
    t : Nat <- tty.idle(now)
    +x : Nat <- x.idle(c)
    a : Bool <- ac()
    +b : Ran <- run.out("pgrep", ["-f", "switch-to-configuration|nixos-rebuild"], 5000)
    return Facts{hundredths(first.or(List.drop(&2, String, words(la), 1n), "0")), Nat.min(t, x), a, num(out.of(h)), ok.of(b)}

def facts.show(f: Facts) -> String:
  match f:
    case Facts{l, i, a, h, b}:
      "load5 " ++ Nat.show(l) ++ "/100, idle " ++ Nat.show(i) ++ " s, mains " ++ Bool.show(a) ++ ", hour " ++ Nat.show(h) ++ ", switching " ++ Bool.show(b)

def say.all(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case x <> t:
      do IO<Unit>:
        IO.print(x)
        say.all(t)

def idle.exit(why: List<&2, String>) -> IO(Unit):
  match why:
    case Nil{}:
      IO.print("idle")
    case +w <> t:
      do IO<Unit>:
        IO.print("not idle:")
        say.all(w <> t)
        IO.exit(1)

def cmd.idle() -> IO(Unit):
  do IO<Unit>:
    +c : List<&2, String> <- conf()
    +f : Facts <- facts(c)
    IO.print(facts.show(f))
    idle.exit(idle.why(policy.of(c), f))

# enc-update health -----------------------------------------------------------------------------------------

def http.ok(+code: String) -> Bool:
  Bool.or(String.starts_with(code, "2"), String.starts_with(code, "3"))

# a cmd check: it passed if it exited 0; the first of its output, to show
def check.of.cmd(n: String, r: Ran) -> Check:
  match r:
    case Ran{code, out}:
      Check{U32.is_eq(code, 0), "cmd " ++ n, String.take(String.trim(out), 200n)}

# one line of /etc/enc-update/health: unit NAME | http NAME URL [RESOLVE] | cmd NAME PROG ARGS...
def check.run.go(fs: List<&2, String>) -> IO(Maybe<&2, Check>):
  match fs:
    case "unit" <> +u <> _:
      do IO<Maybe<&2, Check>>:
        +r : Ran <- run.out("systemctl", ["is-active", u], 20000)
        +s : String = out.of(r)
        return Some{Check{String.eq(s, "active"), "unit " ++ u, s}}
    case "http" <> +n <> +url <> Nil{}:
      do IO<Maybe<&2, Check>>:
        +r : Ran <- run.out("curl", ["-s", "-o", "/dev/null", "-m", "20", "-w", "%{http_code}", url], 30000)
        +s : String = out.of(r)
        return Some{Check{http.ok(s), "http " ++ n, s}}
    case "http" <> +n <> +url <> +res <> _:
      do IO<Maybe<&2, Check>>:
        +r : Ran <- run.out("curl", ["-s", "-o", "/dev/null", "-m", "20", "-w", "%{http_code}", "--resolve", res, url], 30000)
        +s : String = out.of(r)
        return Some{Check{http.ok(s), "http " ++ n, s}}
    case "cmd" <> +n <> +p <> args:
      do IO<Maybe<&2, Check>>:
        +r : Ran <- run.ms(p, args.lin(args), 60000)
        return Some{check.of.cmd(n, r)}
    case _:
      IO.pure(Maybe<&2, Check>, None{})

def check.run(+l: String) -> IO(Maybe<&2, Check>):
  check.run.go(words(l))

def checks.run(ls: List<&2, String>) -> IO(List<&2, Check>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, Check>, Nil{})
    case +l <> t:
      do IO<List<&2, Check>>:
        m : Maybe<&2, Check> <- check.run(l)
        r : List<&2, Check> <- checks.run(t)
        return checks.put(m, r)

def failed.of(ls: List<&2, String>) -> List<&2, Check>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      Check{False{}, "failed " ++ first.or(words(l), "?"), ""} <> failed.of(t)

def health() -> IO(List<&2, Check>):
  do IO<List<&2, Check>>:
    e : String <- etc()
    t : String <- file.text(e ++ "/health")
    cs : List<&2, Check> <- checks.run(String.lines(t))
    +r : Ran <- run.out("systemctl", ["--failed", "--plain", "--no-legend", "--no-pager"], 20000)
    return List.append(&2, Check, cs, failed.of(lines(out.of(r))))

def checks.say(xs: List<&2, Check>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case c <> t:
      do IO<Unit>:
        IO.print(check.line(c))
        checks.say(t)

def cmd.health() -> IO(Unit):
  do IO<Unit>:
    cs : List<&2, Check> <- health()
    checks.say(cs)

# enc-update guard FILE ---------------------------------------------------------------------------------------

def guard.exit(bad: List<&2, String>) -> IO(Unit):
  match bad:
    case Nil{}:
      IO.print("nothing forbidden to build")
    case +b <> t:
      do IO<Unit>:
        IO.print("would build, so refused:")
        say.all(b <> t)
        IO.exit(1)

def cmd.guard(path: String) -> IO(Unit):
  do IO<Unit>:
    +c : List<&2, String> <- conf()
    t : String <- file.text(path)
    guard.exit(guard(conf.all(c, "forbid"), t))

# enc-update run: the builder's cycle -----------------------------------------------------------------------------

def state() -> String:
  "/var/lib/enc-update"

# the builder's own clone and results, the user's (git and GitHub as him)
def udir() -> String:
  "/var/lib/enc-update/u"

def clone() -> String:
  "/var/lib/enc-update/u/enc"

def logline(+t: String) -> IO(Unit):
  do IO<Unit>:
    +n : Ran <- run.out("date", ["+%F %T"], 5000)
    +l : String = out.of(n) ++ " " ++ t
    IO.print(l)
    file.put(state() ++ "/log", l ++ "\n", "a")

# a program run as the user (his ssh keys and GitHub): runuser -u USER -- env HOME=... PROG ARGS
def as.user(+c: List<&2, String>, prog: String, args: List<String>, ms: U32) -> IO(Ran):
  +u = conf.get(c, "user", "hhefesto")
  run.ms("runuser", "-u" <> u <> "--" <> "env" <> ("HOME=/home/" ++ u) <> prog <> args, ms)

def as.user.out(+c: List<&2, String>, prog: String, args: List<String>, ms: U32) -> IO(Ran):
  +u = conf.get(c, "user", "hhefesto")
  run.out("runuser", "-u" <> u <> "--" <> "env" <> ("HOME=/home/" ++ u) <> prog <> args, ms)

# a target: NAME, and how to reach it (local, or ssh's USER@HOST)
type Target is Data:
  Target{name: String, at: String}

def target.of.go(ws: List<&2, String>) -> Target:
  match ws:
    case +n <> a <> _:
      Target{n, a}
    case +n <> Nil{}:
      Target{n, "local"}
    case Nil{}:
      Target{"?", "local"}

def target.of(+v: String) -> Target:
  target.of.go(words(v))

def targets.of(vs: List<&2, String>) -> List<&2, Target>:
  match vs:
    case Nil{}:
      Nil{}
    case +v <> t:
      target.of(v) <> targets.of(t)

# a command on a target: there, as root (local: this root; else ssh as the
# user, who is root's authorized key there)
def on.go(local: Bool, +c: List<&2, String>, a: String, prog: String, args: List<String>, ms: U32) -> IO(Ran):
  match local:
    case True{}:
      run.ms(prog, args, ms)
    case False{}:
      as.user(c, "ssh", "-o" <> "BatchMode=yes" <> "-o" <> "ConnectTimeout=20" <> a <> prog <> args, ms)

def on(+c: List<&2, String>, +t: Target, prog: String, args: List<String>, ms: U32) -> IO(Ran):
  match t:
    case Target{n, +a}:
      on.go(String.eq(a, "local"), c, a, prog, args, ms)

def on.out.go(local: Bool, +c: List<&2, String>, a: String, prog: String, args: List<String>, ms: U32) -> IO(Ran):
  match local:
    case True{}:
      run.out(prog, args, ms)
    case False{}:
      as.user.out(c, "ssh", "-o" <> "BatchMode=yes" <> "-o" <> "ConnectTimeout=20" <> a <> prog <> args, ms)

def on.out(+c: List<&2, String>, +t: Target, prog: String, args: List<String>, ms: U32) -> IO(Ran):
  match t:
    case Target{n, +a}:
      on.out.go(String.eq(a, "local"), c, a, prog, args, ms)

def tname(t: Target) -> String:
  match t:
    case Target{n, a}:
      n

# Each target's update ------------------------------------------------------------------------------------------------

# how one target's update went
type Went is Data:
  WOk{}
  WSame{}
  WSkip{why: String}
  WBack{why: String}
  WDown{why: String}

def went.show(w: Went) -> String:
  match w:
    case WOk{}:
      "updated, its checks well"
    case WSame{}:
      "already on this system"
    case WSkip{why}:
      "not updated: " ++ why
    case WBack{why}:
      "BROKEN by the update and switched back: " ++ why
    case WDown{why}:
      "BROKEN by the update, and switching back FAILED: " ++ why

def system(+c: List<&2, String>, +t: Target) -> IO(String):
  do IO<String>:
    +r : Ran <- on.out(c, t, "readlink", ["-f", "/run/current-system"], 60000)
    return out.of(r)

def health.of(+c: List<&2, String>, +t: Target) -> IO(List<&2, Check>):
  do IO<List<&2, Check>>:
    +r : Ran <- on.out(c, t, "enc-update", ["health"], 900000)
    return checks.of(lines(out.of(r)))

# the system profile set to p and switched to, in a unit of its own (a
# restarted sshd, or this service's own restart, can't stop it halfway)
def switch(+c: List<&2, String>, +t: Target, +p: String) -> IO(Bool):
  do IO<Bool>:
    +a : Ran <- on(c, t, "nix-env", ["-p", "/nix/var/nix/profiles/system", "--set", p], 600000)
    +b : Ran <- on(c, t, "systemd-run", ["--unit=enc-update-switch-" ++ String.take(String.drop(p, 11n), 8n), "--collect", "--wait", "--quiet", "--service-type=exec", p ++ "/bin/switch-to-configuration", "switch"], 3600000)
    IO.sleep(5000)
    now : String <- system(c, t)
    return String.eq(now, p)

def settle() -> IO(Unit):
  IO.sleep(90000)

def back(+c: List<&2, String>, +t: Target, +old: String, +why: String) -> IO(Went):
  do IO<Went>:
    logline(tname(t) ++ ": broken (" ++ why ++ "): switching back to " ++ old)
    ok : Bool <- switch(c, t, old)
    settle()
    hs : List<&2, Check> <- health.of(c, t)
    +bad : List<&2, String> = broke(Nil{}, hs)
    logline(tname(t) ++ ": after switching back, failing: " ++ String.join(bad, "; "))
    return Bool.pick(Went, ok, WBack{why}, WDown{why})

def judged(+c: List<&2, String>, +t: Target, +old: String, +before: List<&2, Check>, bad: List<&2, String>) -> IO(Went):
  match bad:
    case Nil{}:
      do IO<Went>:
        logline(tname(t) ++ ": updated, every check as before or better")
        return WOk{}
    case +b <> r:
      back(c, t, old, String.join(b <> r, "; "))

# a break must stay: checked again a while later (a service still restarting)
def judge2(+c: List<&2, String>, +t: Target, +old: String, +before: List<&2, Check>, bad: List<&2, String>) -> IO(Went):
  match bad:
    case Nil{}:
      judged(c, t, old, before, Nil{})
    case +b <> r:
      do IO<Went>:
        logline(tname(t) ++ ": failing after the switch: " ++ String.join(b <> r, "; ") ++ "; checking again in 2 minutes")
        IO.sleep(120000)
        hs : List<&2, Check> <- health.of(c, t)
        judged(c, t, old, before, broke(before, hs))

def after.switch(ok: Bool, +c: List<&2, String>, +t: Target, +old: String, +before: List<&2, Check>) -> IO(Went):
  match ok:
    case False{}:
      back(c, t, old, "the switch did not end on the new system")
    case True{}:
      do IO<Went>:
        settle()
        hs : List<&2, Check> <- health.of(c, t)
        judge2(c, t, old, before, broke(before, hs))

def gates.go(+c: List<&2, String>, gs: List<&2, String>) -> IO(List<&2, String>):
  match gs:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +g <> t:
      do IO<List<&2, String>>:
        +r : Ran <- as.user(c, "nix", ["run", "--no-write-lock-file", clone() ++ "#" ++ g], 1800000)
        rest : List<&2, String> <- gates.go(c, t)
        return keep.put(ok.of(r), g ++ ": " ++ String.take(tail.of(r), 300n), rest)

# a target's own gates before its switch (xty: deploy-xty's checks): GATE
# NAME APP, the flake's app run as the user
def gates(+c: List<&2, String>, +t: Target) -> IO(List<&2, String>):
  gates.go(c, conf.all(c, "gate." ++ tname(t)))

def copy(+c: List<&2, String>, +t: Target, p: String) -> IO(Ran):
  match t:
    case Target{n, +a}:
      Bool.pick(IO(Ran), String.eq(a, "local"), IO.pure(Ran, Ran{0, ""}), as.user(c, "nix", ["copy", "--to", "ssh-ng://" ++ a, p], 14400000))

# copied there: switched; not (the network, a full disk): skipped, nothing changed
def go.copied(ok: Bool, +c: List<&2, String>, +t: Target, +p: String, +old: String, +before: List<&2, Check>, +cp: Ran) -> IO(Went):
  match ok:
    case False{}:
      IO.pure(Went, WSkip{"copying its system there FAILED: " ++ String.take(tail.of(cp), 300n)})
    case True{}:
      do IO<Went>:
        sw : Bool <- switch(c, t, p)
        after.switch(sw, c, t, old, before)

def go.target(+c: List<&2, String>, +t: Target, +p: String, +old: String, gbad: List<&2, String>) -> IO(Went):
  match gbad:
    case +g <> r:
      IO.pure(Went, WSkip{"its gates failed: " ++ String.join(g <> r, "; ")})
    case Nil{}:
      do IO<Went>:
        +before : List<&2, Check> <- health.of(c, t)
        logline(tname(t) ++ ": " ++ Nat.show(len(broke(Nil{}, before))) ++ " checks failing before; copying and switching to " ++ p)
        +cp : Ran <- copy(c, t, p)
        go.copied(ok.of(cp), c, t, p, old, before, cp)

def idle.there(+c: List<&2, String>, +t: Target) -> IO(Ran):
  on(c, t, "enc-update", ["idle"], 120000)

def update.from(same: Bool, none: Bool, +c: List<&2, String>, +t: Target, +p: String, +old: String) -> IO(Went):
  match same none:
    case True{} _:
      IO.pure(Went, WSame{})
    case False{} True{}:
      IO.pure(Went, WSkip{"its current system could not be read"})
    case False{} False{}:
      do IO<Went>:
        gb : List<&2, String> <- gates(c, t)
        go.target(c, t, p, old, gb)

def update.idle.go(ok: Bool, +ir: Ran, +c: List<&2, String>, +t: Target, +p: String) -> IO(Went):
  match ok:
    case False{}:
      IO.pure(Went, WSkip{String.take(tail.of(ir), 300n)})
    case True{}:
      do IO<Went>:
        +old : String <- system(c, t)
        update.from(String.eq(old, p), String.is_empty(old), c, t, p, old)

def update.idle(+ir: Ran, +c: List<&2, String>, +t: Target, +p: String) -> IO(Went):
  update.idle.go(ok.of(ir), ir, c, t, p)

def update(+c: List<&2, String>, +t: Target, +p: String) -> IO(Went):
  do IO<Went>:
    +ir : Ran <- idle.there(c, t)
    update.idle(ir, c, t, p)

# whether to go on to the next target after one went so
def fine(w: Went) -> Bool:
  match w:
    case WOk{}:
      True{}
    case WSame{}:
      True{}
    case WSkip{_}:
      True{}
    case WBack{_}:
      False{}
    case WDown{_}:
      False{}

def done(w: Went) -> Bool:
  match w:
    case WOk{}:
      True{}
    case WSame{}:
      True{}
    case _:
      False{}

# Summing up ---------------------------------------------------------------------------------------

type Sum is Data:
  Sum{all_done: Bool, broken: Bool, text: String}

def sum.put(+n: String, +w: Went, s: Sum) -> Sum:
  match s:
    case Sum{a, b, t}:
      Sum{Bool.and(done(w), a), Bool.or(Bool.not(fine(w)), b), n ++ ": " ++ went.show(w) ++ "\n" ++ t}

# one target's turn: its update, if no earlier target's update broke
def target.step(on: Bool, +c: List<&2, String>, +t: Target, +res: String) -> IO(Went):
  match on:
    case True{}:
      do IO<Went>:
        +p : String = res ++ "/" ++ tname(t)
        +rp : Ran <- run.out("readlink", ["-f", p], 10000)
        +w : Went <- update(c, t, out.of(rp))
        logline(tname(t) ++ ": " ++ went.show(w))
        return w
    case False{}:
      IO.pure(Went, WSkip{"not updated: an earlier machine's update broke"})

# the targets in order; once one's update breaks, the rest are not touched
def targets.go(+c: List<&2, String>, ts: List<&2, Target>, +res: String, +on: Bool) -> IO(Sum):
  match ts:
    case Nil{}:
      IO.pure(Sum, Sum{True{}, False{}, ""})
    case +t <> r:
      do IO<Sum>:
        +w : Went <- target.step(on, c, t, res)
        s : Sum <- targets.go(c, r, res, Bool.and(on, fine(w)))
        return sum.put(tname(t), w, s)

# The lock --------------------------------------------------------------------------------------------

def dry(+c: List<&2, String>, +outs: List<&2, String>) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +r : Ran <- as.user(c, "nix", "build" <> "--dry-run" <> "--no-write-lock-file" <> args.lin(outs), 3600000)
    return guard(conf.all(c, "forbid"), out.of(r))

def lock.save(+c: List<&2, String>) -> IO(Ran):
  as.user(c, "cp", [clone() ++ "/flake.lock", udir() ++ "/flake.lock.ok"], 60000)

def lock.back(+c: List<&2, String>) -> IO(Ran):
  as.user(c, "cp", [udir() ++ "/flake.lock.ok", clone() ++ "/flake.lock"], 60000)

def try.one.fin(+c: List<&2, String>, +i: String, bad: List<&2, String>) -> IO(Bool):
  match bad:
    case Nil{}:
      IO.pure(Bool, True{})
    case +b <> r:
      do IO<Bool>:
        logline("input " ++ i ++ " not updated: it would build " ++ String.join(b <> r, ", "))
        +x : Ran <- lock.back(c)
        return False{}

# one input updated on its own: kept if the dry run builds nothing forbidden, else put back
def try.one(+c: List<&2, String>, +outs: List<&2, String>, +i: String) -> IO(Bool):
  do IO<Bool>:
    +s : Ran <- lock.save(c)
    +u : Ran <- as.user(c, "nix", ["flake", "update", i, "--flake", clone()], 1800000)
    bad : List<&2, String> <- dry(c, outs)
    try.one.fin(c, i, bad)

# the inputs, one at a time, in order; the ones kept
def try.inputs(+c: List<&2, String>, +outs: List<&2, String>, ins: List<&2, String>, kept: List<&2, String>) -> IO(List<&2, String>):
  match ins:
    case Nil{}:
      IO.pure(List<&2, String>, kept)
    case +i <> t:
      do IO<List<&2, String>>:
        ok : Bool <- try.one(c, outs, i)
        try.inputs(c, outs, t, keep.put(Bool.not(ok), i, kept))

def inputs.all(+c: List<&2, String>, +outs: List<&2, String>, bad: List<&2, String>) -> IO(Unit):
  match bad:
    case Nil{}:
      logline("every input updated, nothing forbidden to build")
    case +b <> r:
      do IO<Unit>:
        logline("updating every input would build " ++ String.join(b <> r, ", ") ++ ": one input at a time")
        +x : Ran <- as.user(c, "git", ["-C", clone(), "checkout", "flake.lock"], 60000)
        kept : List<&2, String> <- try.inputs(c, outs, conf.all(c, "input"), Nil{})
        logline("inputs updated: " ++ String.join(kept, " "))

def outs() -> List<&2, String>:
  [clone() ++ "#packages.x86_64-linux.default", clone() ++ "#checks.x86_64-linux.pre-deploy-xty"]

def fresh.clone(have: Bool, +c: List<&2, String>) -> IO(Ran):
  match have:
    case True{}:
      IO.pure(Ran, Ran{0, ""})
    case False{}:
      as.user(c, "git", ["clone", "-q", conf.get(c, "repo", "git@github.com:hhefesto/enc.git"), clone()], 600000)

# the clone at origin's branch, fresh
def fresh(+c: List<&2, String>) -> IO(Bool):
  do IO<Bool>:
    +br : String = conf.get(c, "branch", "master")
    +h : Ran <- run.out("test", ["-d", clone() ++ "/.git"], 5000)
    +k : Ran <- fresh.clone(ok.of(h), c)
    +f : Ran <- as.user(c, "git", ["-C", clone(), "fetch", "-q", "origin", br], 600000)
    +r : Ran <- as.user(c, "git", ["-C", clone(), "reset", "-q", "--hard", "origin/" ++ br], 60000)
    +x : Ran <- as.user(c, "git", ["-C", clone(), "clean", "-qfdx"], 60000)
    return Bool.and(ok.of(f), ok.of(r))

def lock.hash(+c: List<&2, String>) -> IO(String):
  do IO<String>:
    +r : Ran <- run.out("sha256sum", [clone() ++ "/flake.lock"], 10000)
    return first.or(words(out.of(r)), "")

def stamp() -> IO(Nat):
  do IO<Nat>:
    t : String <- file.text(state() ++ "/last-ok")
    return num(String.trim(t))

def now.s() -> IO(Nat):
  do IO<Nat>:
    +n : Ran <- run.out("date", ["+%s"], 5000)
    return num(out.of(n))

def hand.push(+c: List<&2, String>, push: String) -> IO(Unit):
  match push:
    case "master":
      do IO<Unit>:
        +r : Ran <- as.user(c, "git", ["-C", clone(), "push", "-q", "origin", "HEAD:refs/heads/" ++ conf.get(c, "branch", "master")], 300000)
        logline(Bool.pick(String, ok.of(r), "pushed to GitHub's master", "push to master FAILED (master moved?): " ++ tail.of(r)))
    case "branch":
      do IO<Unit>:
        +r : Ran <- as.user(c, "git", ["-C", clone(), "push", "-q", "-f", "origin", "HEAD:refs/heads/enc-update"], 300000)
        logline(Bool.pick(String, ok.of(r), "pushed to GitHub's branch enc-update", "push to enc-update FAILED: " ++ tail.of(r)))
    case _:
      logline("not pushed (push none)")

# the lock handed on: committed in the clone, then as `push` says
def hand.on(+c: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +d : Ran <- run.out("date", ["+%F"], 5000)
    +a : Ran <- as.user(c, "git", ["-C", clone(), "commit", "-q", "-m", "flake.lock: enc-update " ++ out.of(d) ++ ", every machine updated and its checks well", "flake.lock"], 60000)
    +u : String = conf.get(c, "user", "hhefesto")
    +push : String = conf.get(c, "push", "none")
    +l : Ran <- as.user(c, "git", ["-C", "/home/" ++ u ++ "/src/enc", "fetch", "-q", clone(), "+HEAD:refs/heads/enc-update"], 120000)
    logline("the lock commit: branch enc-update of ~/src/enc " ++ Bool.pick(String, ok.of(l), "(fetched)", "(fetch FAILED: " ++ tail.of(l) ++ ")"))
    hand.push(c, push)

def finish.go(all: Bool, broken: Bool, +c: List<&2, String>, +h: String, +t: String) -> IO(Unit):
  match all broken:
    case _ True{}:
      do IO<Unit>:
        file.put(state() ++ "/bad-locks", h ++ "\n", "a")
        logline("this lock broke a machine; it is not tried again (" ++ state() ++ "/bad-locks)")
        IO.exit(2)
    case True{} False{}:
      do IO<Unit>:
        n : Nat <- now.s()
        file.put(state() ++ "/last-ok", Nat.show(n) ++ "\n", "w")
        hand.on(c)
    case False{} False{}:
      logline("not every machine was idle: the next run goes on")

def finish(+c: List<&2, String>, +h: String, s: Sum) -> IO(Unit):
  match s:
    case Sum{a, b, +t}:
      do IO<Unit>:
        file.put(state() ++ "/status", t, "w")
        finish.go(a, b, c, h, t)

def cycle.built(ok: Bool, +c: List<&2, String>, +h: String, +b: Ran) -> IO(Unit):
  match ok:
    case False{}:
      do IO<Unit>:
        logline("the build FAILED, nothing switched: " ++ tail.of(b))
        file.put(state() ++ "/status", "the build failed; nothing switched\n", "w")
        IO.exit(2)
    case True{}:
      do IO<Unit>:
        s : Sum <- targets.go(c, targets.of(conf.all(c, "target")), udir() ++ "/result", True{})
        finish(c, h, s)

def cycle.lock(changed: Bool, bad: Bool, +c: List<&2, String>, +h: String) -> IO(Unit):
  match changed bad:
    case False{} _:
      do IO<Unit>:
        logline("no input has a newer version that builds nothing forbidden: nothing to do")
        file.put(state() ++ "/status", "nothing new\n", "w")
    case True{} True{}:
      logline("this lock broke a machine before: not tried again")
    case True{} False{}:
      do IO<Unit>:
        logline("building every machine's system")
        +b : Ran <- as.user(c, "nix", ["build", "--no-write-lock-file", "--keep-going", "--out-link", udir() ++ "/result", clone() ++ "#packages.x86_64-linux.default", clone() ++ "#checks.x86_64-linux.pre-deploy-xty"], 4294967295)
        cycle.built(ok.of(b), c, h, b)

# only the inputs the config names (INPUT NAME) are updated: none named, none
# updated (a bare `nix flake update` would update every input, the user's own
# projects too, and deploy their masters)
def cycle.inputs(ins: List<&2, String>, +c: List<&2, String>) -> IO(Unit):
  match ins:
    case Nil{}:
      logline("no input lines in the config: nothing to update")
    case +i <> r:
      do IO<Unit>:
        +u : Ran <- as.user(c, "nix", "flake" <> "update" <> "--flake" <> clone() <> args.lin(i <> r), 1800000)
        bad : List<&2, String> <- dry(c, outs())
        inputs.all(c, outs(), bad)
        +d : Ran <- as.user(c, "git", ["-C", clone(), "diff", "--quiet", "flake.lock"], 60000)
        +h : String <- lock.hash(c)
        bl : String <- file.text(state() ++ "/bad-locks")
        cycle.lock(Bool.not(ok.of(d)), has(lines(bl), h), c, h)

def cycle.fresh(ok: Bool, +c: List<&2, String>) -> IO(Unit):
  match ok:
    case False{}:
      logline("could not fetch enc: nothing done")
    case True{}:
      cycle.inputs(conf.all(c, "input"), c)

def cycle(+c: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    logline("enc-update: a cycle starts")
    ok : Bool <- fresh(c)
    cycle.fresh(ok, c)

def cycle.gate(recent: Bool, why: List<&2, String>, +c: List<&2, String>) -> IO(Unit):
  match recent why:
    case True{} _:
      IO.print("updated within every.hours: nothing to do")
    case False{} Nil{}:
      cycle(c)
    case False{} +w <> t:
      IO.print("not idle (" ++ String.join(w <> t, "; ") ++ "): next time")

def cycle.when(force: Bool, +c: List<&2, String>) -> IO(Unit):
  match force:
    case True{}:
      cycle(c)
    case False{}:
      do IO<Unit>:
        last : Nat <- stamp()
        n : Nat <- now.s()
        +every : Nat = Nat.mul(num(conf.get(c, "every.hours", "20")), 3600n)
        +f : Facts <- facts(c)
        cycle.gate(Nat.is_lt(Nat.sub(n, last), every), idle.why(policy.of(c), f), c)

def cmd.status() -> IO(Unit):
  do IO<Unit>:
    s : String <- file.text(state() ++ "/status")
    l : String <- file.text(state() ++ "/last-ok")
    IO.print(s)
    IO.print("last finished update (epoch s): " ++ String.trim(l))

# main ------------------------------------------------------------------------------------------------------

def usage() -> String:
  "usage: enc-update idle | health | guard FILE | run [--now] | status"

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case "idle" <> Nil{}:
      cmd.idle()
    case "health" <> Nil{}:
      cmd.health()
    case "guard" <> p <> Nil{}:
      cmd.guard(p)
    case "run" <> Nil{}:
      do IO<Unit>:
        +c : List<&2, String> <- conf()
        cycle.when(False{}, c)
    case "run" <> "--now" <> Nil{}:
      do IO<Unit>:
        +c : List<&2, String> <- conf()
        cycle.when(True{}, c)
    case "status" <> Nil{}:
      cmd.status()
    case _:
      IO.die(Unit, 2, usage())

def args.main(xs: List<String>) -> IO(Unit):
  match xs:
    case _ <> rest:
      args(rest)
    case Nil{}:
      IO.die(Unit, 2, usage())

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    args.main(argv)
