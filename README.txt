JSON.R4P
========

Rolle format.json, Kategorie data. Liest und aendert JSON, ohne Heap und ohne
Baum. Damit kann ein Programm JSON verarbeiten, ohne selbst JSON zu koennen:
Der Parser liegt EINMAL im System, nicht als Kopie in jedem Binary.

Aufbau
------

    src/json_core.zig   der Kern: Tokenizer, Selektor, Iterator, Aenderungen.
                        Ohne r4os-Abhaengigkeit, damit derselbe Produktivcode
                        in Inline-Tests auf dem Host laeuft.
    src/main.zig        duenner R4P-Rahmen: uebersetzt zwischen
                        ProtocolBuffer und dem Kern, sonst nichts.

Der Aufrufer besitzt den Zustand
--------------------------------

protocolDispatch ist zustandslos - Rolle, Opcode, rein, raus. Ein Cursor lebt
aber ueber mehrere Aufrufe. Deshalb besitzt der AUFRUFER den Cursor samt
Tiefenfeld und gibt ihn in der Request mit. Das Modul haelt keine Sitzungen,
keine Besitzverhaeltnisse und keine Lebensdauern.

Die Groesse des Tiefenfeldes IST die Verschachtelungsgrenze. Wer flache
Inventare liest, nimmt 8; wer tiefere Dokumente erwartet, nimmt mehr. Das
Protokoll fuehrt selbst keine Grenze.

Bytegrenzen
-----------

Jedes Token meldet seine exakten Grenzen im Dokument. Das ist die
Voraussetzung fuers Aendern: set, remove und insert kopieren die unberuehrten
Bereiche byteweise durch und ersetzen nur an der Zielstelle. Formatierung und
Schluesselreihenfolge des restlichen Dokuments bleiben byteidentisch - eine
Aenderung an einer eingecheckten Datei ergibt einen Diff von einer Zeile
statt einer Neuformatierung.

Operationen
-----------

    1 open           Dokument an den Cursor binden
    2 next           naechstes Token
    3 select         Cursor auf den Wert unter einem Pfad
    4 value          Rohbytes des aktuellen Tokens ausgeben
    5 enter          in das aktuelle Array oder Objekt hinein
    6 next_element   naechstes Element derselben Ebene
    7 set            Wert ersetzen
    8 remove         Member oder Element entfernen
    9 insert         als letztes Element in ein Array einfuegen

Pfadsyntax: Schluessel mit Punkt, Index mit [n]. Sonst nichts - keine
Platzhalter, keine Filter, keine Suche. Andernfalls waere das eine
Abfragesprache und kein Selektor.

Was ausdruecklich nicht dazugehoert
-----------------------------------

Das Protokoll kennt keine Bedeutung der Daten. Es weiss nicht, was ein Modul
ist, kennt keine Pflichtfelder und prueft keine Duplikate. Wer insert zweimal
mit demselben Namen ruft, bekommt zwei Eintraege; das zu verhindern ist Sache
des Aufrufers.

Es dekodiert auch keine Escapes. Werte kommen roh heraus, und der
Pfadvergleich arbeitet auf den Rohbytes des Schluessels.

Der atomare Schreibweg gehoert nicht hierher, sondern in die Fassade: Das
Protokoll liefert nur die neuen Bytes, das Schreiben in eine Datei ist
R4OS-spezifisch.

Fassade
-------

    Gepinntes SDK-Paket: r4os/json.zig

Ein Programm schreibt damit keine Opcodes und keine Puffer:

    var speicher: [16]u8 = undefined;
    var doc = json.Document.init(&dev, bytes, &speicher);
    const version = try doc.readString("entries[3].version", &puffer);

Die Fassade bettet den Parser NICHT ein - sonst traege jedes Programm seine
eigene Kopie, und eine Korrektur muesste ueberall neu gebaut werden. Beide
Seiten deklarieren dieselben Strukturen getrennt; dass sie binaergleich
bleiben, sichert Tests/Conformance/CheckJsonAbi.zig.

Tests
-----

    Build.bat test

Das fertige Modul liegt standardmaessig unter
`D:\R4OS\Artifacts\Modules\JSON\JSON.R4P`. `Settings.R4S` mappt SDK,
Contract, DevKit, Zig und die Artefaktausgabe relativ oder absolut. Auch der
ABI-Test bezieht seine Fassade aus der gepinnten SDK-Abhaengigkeit und kennt
keinen Nachbarpfad.

Image-Zielpfad: C:\R4OS\PROTOCOLS\JSON.R4P

Herkunft und Transfergrenzen stehen in `PROVENANCE.txt`.
