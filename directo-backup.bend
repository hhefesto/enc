import Base

# directo-backup: directo's database, out of xty every night, and restored
# from the backup every time to show the backup works.  The user, 11-26,
# chose where the backups go: "olimpo pulls a nightly dump from xty over ssh
# into a local restic repo, with a copy on delfos"; and where the drill runs:
# "directly against the live directo.hhefesto.dev".
#
#   directo-backup backup   a dump of xty's directo into olimpo's restic repo,
#                           then the drill, then the copy to delfos
#   directo-backup drill    the drill alone, on the newest snapshot
#   directo-backup status   the snapshots on olimpo, and on delfos when it's up
#
# The dump is plain SQL from xty's own pg_dump (PostgreSQL 16, the server's
# version), read over ssh as root, run as postgres; restic stores it as it
# comes (--stdin-from-command: a failed pg_dump makes no snapshot).
#
# The drill restores the newest snapshot into directo_drill, a database of its
# own on xty's live PostgreSQL, next to directo.  It then reads every table of
# both, its rows' count and an md5 of all its rows, and drops directo_drill.
# It never writes directo itself (the laws below): restoring over the live
# database would erase whatever was written since the dump.  Its verdict:
#   pass    the same tables, the same rows
#   differ  the same tables, some rows changed: something was written on the
#           live site between the dump and the drill (the tables are named)
#   fail    a table missing or extra, no tables, or a step that failed
#
# The copy to delfos is `restic copy`: every snapshot delfos lacks.  When
# delfos is off the copy waits for the next run, which catches up.
#
# Nothing is ever pruned: every snapshot stays (forgetting old ones deletes
# backups, which waits for the owner's OK).  The repos' password is the agenix
# secret directo-backup-restic (secrets/secrets.nix); the shim,
# directo-backup.nix, hands restic its path.

# Where things are --------------------------------------------------------------

def xty() -> String:
  "root@62.238.6.4"

def delfos() -> String:
  "hhefesto@192.168.3.6"

def live.db() -> String:
  "directo"

def drill.db() -> String:
  "directo_drill"

def backups() -> String:
  "/home/hhefesto/backups"

def repo() -> String:
  "/home/hhefesto/backups/directo-restic"

def delfos.repo() -> String:
  "sftp:hhefesto@192.168.3.6:/home/hhefesto/backups/directo-restic"

def dump.file() -> String:
  "directo.sql"

# What runs on xty (each string is one ssh command there) --------------------------------

def as.pg(c: String) -> String:
  "sudo -u postgres " ++ c

def dump.cmd() -> String:
  as.pg("pg_dump " ++ live.db())

def drop.cmd() -> String:
  as.pg("dropdb --if-exists " ++ drill.db())

def create.cmd() -> String:
  as.pg("createdb " ++ drill.db())

def psql.cmd(db: String) -> String:
  as.pg("psql -X -q -At -v ON_ERROR_STOP=1 -d " ++ db)

def load.cmd() -> String:
  psql.cmd(drill.db())

# every table of the public schema, one line each: name|rows|md5 of its rows
def rows.sql() -> String:
  "select table_name || '|' || x.c || '|' || x.h\n" ++
  "from information_schema.tables,\n" ++
  "lateral (select (xpath('/row/c/text()', q))[1]::text as c,\n" ++
  "                (xpath('/row/h/text()', q))[1]::text as h\n" ++
  "         from query_to_xml(format('select count(*) as c, md5(coalesce(string_agg(t::text, '','' order by t::text), '''')) as h from %I.%I t', table_schema, table_name), false, true, '') as q) x\n" ++
  "where table_schema = 'public' and table_type = 'BASE TABLE'\n" ++
  "order by 1;\n"

# The drill's verdict -----------------------------------------------------------------------------

def keep.put(same: Bool, h: String, r: List<&2, String>) -> List<&2, String>:
  match same:
    case True{}:
      r
    case False{}:
      h <> r

def nonempty(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      keep.put(String.is_empty(h), h, nonempty(t))

def trimmed(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      String.trim(h) <> trimmed(t)

def lines(s: String) -> List<&2, String>:
  nonempty(trimmed(String.lines(s)))

def none(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case _ <> _:
      False{}

def len(xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case _ <> t:
      Nat.add(1n, len(t))

def first.or(xs: List<&2, String>, d: String) -> String:
  match xs:
    case Nil{}:
      d
    case h <> _:
      h

def last.or(xs: List<&2, String>, d: String) -> String:
  match xs:
    case Nil{}:
      d
    case h <> t:
      last.or(t, h)

# a table's line, name|rows|md5: its name
def name.of(l: String) -> String:
  first.or(String.split(l, '|'), "")

# the same tables, in the same order (both lists come sorted by the same
# server's collation)
def same.names(a: List<&2, String>, b: List<&2, String>) -> Bool:
  match a:
    case Nil{}:
      none(b)
    case x <> ta:
      match b:
        case Nil{}:
          False{}
        case y <> tb:
          Bool.and(String.eq(name.of(x), name.of(y)), same.names(ta, tb))

# the tables whose rows differ
def changed(a: List<&2, String>, b: List<&2, String>) -> List<&2, String>:
  match a:
    case Nil{}:
      Nil{}
    case +x <> ta:
      match b:
        case Nil{}:
          Nil{}
        case y <> tb:
          keep.put(String.eq(x, y), name.of(x), changed(ta, tb))

def verdict.same(ch: List<&2, String>) -> String:
  Bool.pick(String, none(ch), "pass", "differ")

def verdict.tables(ok: Bool, ch: List<&2, String>) -> String:
  Bool.pick(String, ok, verdict.same(ch), "fail")

# live's lines and the drill's: pass, differ or fail
def verdict(+live: List<&2, String>, +drill: List<&2, String>) -> String:
  verdict.tables(Bool.and(Bool.not(none(live)), same.names(live, drill)), changed(live, drill))

# The laws, checked by the build -------------------------------------------------------------

# the drill's database is never the live one, and the only commands that
# write on xty name the drill's
law drill_not_live:
  {String.eq(drill.db(), live.db()) == False{} : Bool}

def drill_not_live():
  {==}

law drop_names_the_drill:
  {drop.cmd() == "sudo -u postgres dropdb --if-exists directo_drill" : String}

def drop_names_the_drill():
  {==}

law create_names_the_drill:
  {create.cmd() == "sudo -u postgres createdb directo_drill" : String}

def create_names_the_drill():
  {==}

law load_into_the_drill:
  {load.cmd() == "sudo -u postgres psql -X -q -At -v ON_ERROR_STOP=1 -d directo_drill" : String}

def load_into_the_drill():
  {==}

# the dump only reads the live database
law dump_reads_live:
  {dump.cmd() == "sudo -u postgres pg_dump directo" : String}

def dump_reads_live():
  {==}

law same_rows_pass:
  {verdict(["orders|1|aa", "products|87|bb"], ["orders|1|aa", "products|87|bb"]) == "pass" : String}

def same_rows_pass():
  {==}

law written_since_differs:
  {verdict(["orders|2|cc", "products|87|bb"], ["orders|1|aa", "products|87|bb"]) == "differ" : String}

def written_since_differs():
  {==}

law lost_table_fails:
  {verdict(["orders|1|aa", "products|87|bb"], ["orders|1|aa"]) == "fail" : String}

def lost_table_fails():
  {==}

law extra_table_fails:
  {verdict(["orders|1|aa"], ["orders|1|aa", "products|87|bb"]) == "fail" : String}

def extra_table_fails():
  {==}

law renamed_table_fails:
  {verdict(["orders|1|aa", "products|87|bb"], ["orders|1|aa", "productos|87|bb"]) == "fail" : String}

def renamed_table_fails():
  {==}

# nothing restored (a failed load) is no pass, even against nothing
law nothing_fails:
  {verdict([], []) == "fail" : String}

def nothing_fails():
  {==}

law changed_names_tables:
  {changed(["orders|2|cc", "products|87|bb"], ["orders|1|aa", "products|87|bb"]) == ["orders"] : List<&2, String>}

def changed_names_tables():
  {==}

# The machine -------------------------------------------------------------------------------------

type Ran is Data:
  Ran{code: U32, out: String}

type Check is Data:
  Check{ok: Bool, name: String, detail: String}

# a program's exit status, with its stdout and stderr together (127: it could
# not start, or it timed out)
def got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> Ran:
  match r:
    case Done{(code, (out, err))}:
      Ran{code, String.append(out, err)}
    case Fail{(code, msg)}:
      Ran{127, msg}

# the same with stdout only, untouched (for a dump, or output to parse)
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

def run.out(prog: String, args: List<String>, ms: U32) -> IO(Ran):
  do IO<Ran>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, args, "", 67108864, ms)
    return got.out(r)

# the program reads input on its stdin
def run.in(prog: String, args: List<String>, input: String, ms: U32) -> IO(Ran):
  do IO<Ran>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, args, input, 67108864, ms)
    return got(r)

def run.in.out(prog: String, args: List<String>, input: String, ms: U32) -> IO(Ran):
  do IO<Ran>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, args, input, 67108864, ms)
    return got.out(r)

def ok.of(r: Ran) -> Bool:
  match r:
    case Ran{code, out}:
      U32.is_eq(code, 0)

def raw.of(r: Ran) -> String:
  match r:
    case Ran{code, out}:
      out

def out.of(r: Ran) -> String:
  match r:
    case Ran{code, out}:
      String.trim(out)

# a step's check: it passed if it exited 0; its output's last line, to show
def check.ran(n: String, r: Ran) -> Check:
  match r:
    case Ran{code, out}:
      Check{U32.is_eq(code, 0), n, String.take(last.or(lines(out), ""), 300n)}

# the same, its output shown only when it failed
def check.quiet(n: String, r: Ran) -> Check:
  match r:
    case Ran{+code, out}:
      Check{U32.is_eq(code, 0), n, Bool.pick(String, U32.is_eq(code, 0), "", String.take(last.or(lines(out), ""), 300n))}

# the dump read back: its size
def check.read(r: Ran) -> Check:
  match r:
    case Ran{code, out}:
      Check{U32.is_eq(code, 0), "newest snapshot read", Nat.show(String.length(out)) ++ " characters of SQL"}

def check.ok(c: Check) -> Bool:
  match c:
    case Check{ok, n, d}:
      ok

def check.line(c: Check) -> String:
  match c:
    case Check{ok, n, d}:
      Bool.pick(String, ok, "ok", "FAIL") ++ "\t" ++ n ++ "\t" ++ d

def all.ok(cs: List<&2, Check>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(check.ok(c), all.ok(t))

def checks.say(cs: List<&2, Check>) -> IO(Unit):
  match cs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case c <> t:
      do IO<Unit>:
        IO.print(check.line(c))
        checks.say(t)

def say.all(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case x <> t:
      do IO<Unit>:
        IO.print(x)
        say.all(t)

def exit.if(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.exit(1)

def report(+cs: List<&2, Check>) -> IO(Unit):
  do IO<Unit>:
    checks.say(cs)
    exit.if(all.ok(cs))

def ssh.args(host: String, c: String) -> List<String>:
  ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", host, c]

def on.xty(c: String, ms: U32) -> IO(Ran):
  run.ms("ssh", ssh.args(xty(), c), ms)

# directo-backup backup ------------------------------------------------------------------------------

def repo.init.if(there: Bool) -> IO(Check):
  match there:
    case True{}:
      IO.pure(Check, Check{True{}, "repo", repo()})
    case False{}:
      do IO<Check>:
        +r : Ran <- run.ms("restic", ["-r", repo(), "init"], 120000)
        return check.quiet("repo made " ++ repo(), r)

def repo.ready() -> IO(Check):
  do IO<Check>:
    +m : Ran <- run.ms("install", ["-d", "-m", "700", backups()], 20000)
    +r : Ran <- run.ms("restic", ["-r", repo(), "cat", "config"], 60000)
    repo.init.if(ok.of(r))

def snap.args() -> List<String>:
  ["-r", repo(), "backup", "--stdin-from-command", "--stdin-filename", dump.file(), "--tag", "directo", "--host", "xty", "--", "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", xty(), dump.cmd()]

def snap.take() -> IO(Check):
  do IO<Check>:
    +r : Ran <- run.ms("restic", snap.args(), 1800000)
    return check.ran("snapshot", r)

def verdict.check.say(+v: String, nl: Nat, nd: Nat, +ch: List<&2, String>) -> Check:
  Check{Bool.not(String.eq(v, "fail")), "drill verdict", v ++ ": live " ++ Nat.show(nl) ++ " tables, restored " ++ Nat.show(nd) ++ String.append(Bool.pick(String, none(ch), "", "; rows changed since the dump in: "), String.join(ch, " "))}

def verdict.check(+live: List<&2, String>, +drill: List<&2, String>) -> Check:
  verdict.check.say(verdict(live, drill), len(live), len(drill), changed(live, drill))

# a restored table's line, without the md5 (for the log)
def row.show(fs: List<&2, String>) -> String:
  match fs:
    case n <> r <> _:
      "  " ++ n ++ " " ++ r ++ " rows"
    case _:
      ""

def rows.show(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case l <> t:
      row.show(String.split(l, '|')) <> rows.show(t)

def drill.run() -> IO(List<&2, Check>):
  do IO<List<&2, Check>>:
    +a : Ran <- on.xty(drop.cmd(), 120000)
    +b : Ran <- on.xty(create.cmd(), 120000)
    +s : Ran <- run.out("restic", ["-r", repo(), "dump", "latest", "/" ++ dump.file()], 600000)
    +l : Ran <- run.in("ssh", ssh.args(xty(), load.cmd()), raw.of(s), 1800000)
    +x : Ran <- run.in.out("ssh", ssh.args(xty(), psql.cmd(live.db())), rows.sql(), 300000)
    +y : Ran <- run.in.out("ssh", ssh.args(xty(), psql.cmd(drill.db())), rows.sql(), 300000)
    +z : Ran <- on.xty(drop.cmd(), 120000)
    say.all(rows.show(lines(raw.of(y))))
    return [check.quiet("drill db made", b), check.read(s), check.quiet("restored into " ++ drill.db(), l), verdict.check(lines(raw.of(x)), lines(raw.of(y))), check.quiet("drill db dropped", z)]

def delfos.copy.go(there: Bool) -> IO(Check):
  match there:
    case True{}:
      do IO<Check>:
        +c : Ran <- run.ms("restic", ["-r", delfos.repo(), "copy", "--from-repo", repo()], 1800000)
        return check.ran("delfos copy", c)
    case False{}:
      do IO<Check>:
        +i : Ran <- run.ms("restic", ["-r", delfos.repo(), "init", "--from-repo", repo(), "--copy-chunker-params"], 120000)
        +c : Ran <- run.ms("restic", ["-r", delfos.repo(), "copy", "--from-repo", repo()], 1800000)
        return check.ran("delfos repo made, copy", c)

def delfos.copy.if(up: Bool) -> IO(Check):
  match up:
    case True{}:
      do IO<Check>:
        +r : Ran <- run.ms("restic", ["-r", delfos.repo(), "cat", "config"], 60000)
        delfos.copy.go(ok.of(r))
    case False{}:
      IO.pure(Check, Check{True{}, "delfos copy", "waits: delfos is unreachable; the next run copies every snapshot it lacks"})

def delfos.up() -> IO(Bool):
  do IO<Bool>:
    +u : Ran <- run.ms("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", delfos(), "install -d -m 700 " ++ backups()], 20000)
    return ok.of(u)

def delfos.copy() -> IO(Check):
  do IO<Check>:
    up : Bool <- delfos.up()
    delfos.copy.if(up)

def cmd.backup() -> IO(Unit):
  do IO<Unit>:
    +a : Check <- repo.ready()
    +b : Check <- snap.take()
    ds : List<&2, Check> <- drill.run()
    +c : Check <- delfos.copy()
    report(a <> b <> List.append(&2, Check, ds, [c]))

def cmd.drill() -> IO(Unit):
  do IO<Unit>:
    ds : List<&2, Check> <- drill.run()
    report(ds)

def status.delfos(up: Bool) -> IO(Unit):
  match up:
    case True{}:
      do IO<Unit>:
        +r : Ran <- run.ms("restic", ["-r", delfos.repo(), "snapshots", "--compact"], 120000)
        IO.print("delfos (" ++ delfos.repo() ++ "):")
        IO.print(out.of(r))
    case False{}:
      IO.print("delfos: unreachable")

def cmd.status() -> IO(Unit):
  do IO<Unit>:
    +r : Ran <- run.ms("restic", ["-r", repo(), "snapshots", "--compact"], 120000)
    IO.print("olimpo (" ++ repo() ++ "):")
    IO.print(out.of(r))
    up : Bool <- delfos.up()
    status.delfos(up)

def usage() -> String:
  "usage: directo-backup backup | drill | status"

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case "backup" <> Nil{}:
      cmd.backup()
    case "drill" <> Nil{}:
      cmd.drill()
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
