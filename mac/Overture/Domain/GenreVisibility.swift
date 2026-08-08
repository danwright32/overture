import Foundation

// #1658: one place where a show's genre is written onto a row, so that changing it can never quietly take
// the show away from Dan.
//
// The genre picks the geographic rule (`Discipline.staysInTheBoroughs`: music and band stop at the five
// boroughs, everything else travels about an hour by train), so re-reading a genre has a consequence
// nothing about genre would suggest. Reading the title before the presenter's name moves Taconic Opera's
// two Beethoven nights upstate from opera to music, and both would leave the queue for a reason Dan never
// chose and would never see.
//
// Dan's call, 2026-08-07, shown those two rows: read the title as the genre, AND keep the row visible.
// "Music, but keep it visible."
//
// Every writer of `Prospect.discipline` goes through here, because a second place that writes it is a
// second place the exemption is missing from, and the missing one is always the one nobody tested.
enum GenreVisibility {

    // Writes the genre, recording an exemption when this change alone is what would remove the row.
    //
    // Judged through `GeoRefusals.none`, which applies the built-in geography rules and none of Dan's own
    // town refusals, deliberately: a town he has refused is hidden whatever the genre says, so it is not a
    // change this rule caused, and the exemption below cannot resurrect it either (it only downgrades the
    // row to the loose DISCIPLINE rule, under which a refused town is still refused).
    static func write(_ discipline: Discipline, to prospect: Prospect) {
        let stored = Discipline(rawValue: prospect.discipline) ?? .other
        defer { prospect.discipline = discipline.rawValue }
        guard stored != discipline else { return }

        let wasHidden = GeoRefusals.none.hidesFromQueue(location: prospect.location, discipline: stored)
        let nowHidden = GeoRefusals.none.hidesFromQueue(location: prospect.location, discipline: discipline)
        // Sticky once set. A row that has been kept is kept: a later genre change must not be the thing
        // that finally removes what an earlier one was forbidden to.
        if !wasHidden && nowHidden { prospect.keptVisibleAfterGenreChange = true }
    }
}
