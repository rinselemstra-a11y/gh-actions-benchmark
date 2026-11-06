# GitHub Actions vs eigen hardware

Eén Python-script (`bench.py`, alleen standaardbibliotheek, Python 3.8+) dat
dezelfde tests draait op je eigen Windows/Mac en op de GitHub Actions-runners.
Resultaten komen als JSON terug en kun je met het script naast elkaar zetten.

## Wat wordt gemeten

| test                     | wat                                                   |
|--------------------------|-------------------------------------------------------|
| cpu single-thread        | vaste rekenklus (priemzeef + floating point), seconden |
| cpu multi-thread         | dezelfde klus op alle cores tegelijk, plus speedup     |
| geheugen                 | 512 MB kopiëren, MB/s                                  |
| disk sequentieel         | 512 MB schrijven met fsync en terug lezen, MB/s        |
| disk kleine bestanden    | 3000 bestanden van 4 KB schrijven en lezen (lijkt op git checkout / Maven / npm) |
| eigen commando (optie)   | tijd van bijvoorbeeld `mvn -q package` of `npm run build` |

## Zonder Python: bench.sh en bench.cmd

Dezelfde tests zijn er ook als script zonder Python:

- `bench.sh` voor Mac en Linux (bash, dd, perl voor de tijdmeting; alles standaard aanwezig)
- `bench.cmd` voor Windows (start `bench.ps1` in PowerShell 5.1 of hoger)

```bash
./bench.sh macmini
```

```bash
bench.cmd ws1
```

Argumenten op volgorde: label, workdir, eigen commando. Ze schrijven dezelfde
`result-<label>.json`, dus vergelijken gaat met `bench.py --compare` op een
machine die wel Python heeft, of gewoon door de getallen naast elkaar te leggen.

Let op: de cpu-test in deze scripts is een bash- respectievelijk
PowerShell-loop. Vergelijk bash-resultaten alleen met bash-resultaten
(Mac vs macOS-runner) en PowerShell alleen met PowerShell (Windows vs
Windows-runner). Disk- en geheugentests zijn wel over alle varianten heen
grofweg vergelijkbaar. De workflow draait beide varianten.

## Lokaal draaien (Python)

Windows (PowerShell of cmd):

```bash
python bench.py --label ws1
```

Mac:

```bash
python3 bench.py --label macbook
```

Met een echte build als extra meting (draai het dan vanuit de projectmap of geef
`--workdir` op zodat de disk-test op dezelfde schijf landt):

```bash
python bench.py --label ws1 --cmd "mvn -q -DskipTests package"
```

Dit schrijft `result-<label>.json` in de huidige map.

## Op GitHub Actions draaien: de makkelijke weg

```bash
github-run.cmd
```

Deze batchfile regelt alles: installeert de GitHub CLI (`gh`) als die
ontbreekt, logt in via de browser, maakt eenmalig een privé-repository
`gh-actions-benchmark` op je GitHub-account en pusht deze map, start de
workflow, wacht tot de drie runners klaar zijn, downloadt de resultaten naar
`.\results` en vergelijkt ze met je lokale `result-*.json`. Een eigen
commando geef je als argument mee. Latere keren pusht hij alleen wijzigingen
en start hij opnieuw.

## Op GitHub Actions draaien: handmatig

1. Zet `bench.py` en `.github/workflows/benchmark.yml` in een (test)repository
   en push.
2. GitHub > Actions > "Hardware benchmark" > Run workflow. Eventueel een eigen
   commando invullen, mits de repository dat kan uitvoeren.
3. Na afloop staat per runner (Windows, macOS Apple Silicon, Ubuntu) de uitvoer
   in de joblog en een `result-gh-<os>.json` als artifact. Download die
   artifacts en pak ze uit naast je lokale resultaten.

De matrix in de workflow is makkelijk uit te breiden, bijvoorbeeld met
`macos-15-intel` of een grotere runner zoals `windows-latest-8-cores`.

## Vergelijken

```bash
python bench.py --compare result-ws1.json result-gh-windows-latest.json result-gh-macos-latest.json
```

Het eerste bestand is de referentie. Achter elke andere kolom staat de factor
ten opzichte van die referentie: 2.00x betekent twee keer zo snel, 0.50x half
zo snel. Bij seconden geldt lager is beter, bij MB/s hoger is beter; het script
houdt daar bij de factor rekening mee.

## Kanttekeningen

- Standaard GitHub-runners hebben 4 cores (Windows/Ubuntu) of 3 à 4 cores
  (macOS). Een eigen machine met 8 of meer cores wint de multi-thread-test
  dus vrijwel altijd; kijk voor "hoe snel is een core" naar single-thread.
- Runnerprestaties schommelen per run (gedeelde hardware). Draai twee of drie
  keer voor een eerlijk beeld.
- Het disk-leesresultaat kan uit de OS-cache komen en is daardoor optimistisch.
- De CPU-test is pure Python en meet dus vooral integer/float-snelheid van één
  core; voor een realistische vergelijking is `--cmd` met je echte build het
  nuttigst.
