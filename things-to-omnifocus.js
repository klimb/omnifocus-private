#!/usr/bin/osascript -l JavaScript
// Copy Things 3 areas, projects, tags and to-dos (open and logged) into OmniFocus.
// Usage: osascript -l JavaScript things-to-omnifocus.js [--apply]
// Without --apply it only reads Things and prints what would be created.
// Author: Dmitry Kalashnikov

function run(argv) {
    const apply = argv.indexOf("--apply") >= 0;
    const data = exportThings();
    const summary = "areas=" + data.areas.length + " projects=" + data.projects.length +
        " todos=" + data.todos.length + " (completed=" + data.todos.filter(t => t.status === "completed").length +
        ", canceled=" + data.todos.filter(t => t.status === "canceled").length + ")";
    if (!apply) return "Dry run: " + summary + "\nRe-run with --apply to import.";

    const of = Application("OmniFocus");
    const code = "(" + importIntoOmniFocus.toString() + ")(" + JSON.stringify(data) + ")";
    return "Read " + summary + "\n" + of.evaluateJavascript(code);
}

function exportThings() {
    const t = Application("Things3");
    const iso = d => (d ? d.toISOString() : null);
    const tags = s => (s ? s.split(",").map(x => x.trim()).filter(Boolean) : []);
    const idOf = fn => { try { const r = fn(); return r ? r.id() : null; } catch (e) { return null; } };

    const someday = new Set(t.lists.byName("Someday").toDos.id());
    const today = new Set(t.lists.byName("Today").toDos.id());
    const inbox = new Set(t.lists.byName("Inbox").toDos.id());

    const areas = t.areas().map(a => ({ id: a.id(), name: a.name(), tags: tags(a.tagNames()) }));

    const projectIds = new Set();
    const order = {};
    const projects = t.projects().map(p => {
        const id = p.id();
        projectIds.add(id);
        p.toDos.id().forEach((tid, i) => { order[tid] = i; });
        return {
            id, name: p.name(), notes: p.notes(), status: p.status(),
            areaId: idOf(() => p.area()),
            due: iso(p.dueDate()), defer: iso(p.activationDate()),
            completed: iso(p.completionDate()), canceled: iso(p.cancellationDate()),
            tags: tags(p.tagNames()), someday: someday.has(id),
        };
    });

    const seen = new Set();
    const todos = [];
    ["Inbox", "Today", "Anytime", "Upcoming", "Someday", "Logbook"].forEach(listName => {
        const coll = t.lists.byName(listName).toDos;
        const ids = coll.id();
        if (!ids.length) return;
        const names = coll.name(), notes = coll.notes(), status = coll.status(), tagNames = coll.tagNames();
        const due = coll.dueDate(), act = coll.activationDate();
        const done = coll.completionDate(), canc = coll.cancellationDate();
        const items = coll();
        ids.forEach((id, i) => {
            if (seen.has(id) || projectIds.has(id)) return;
            seen.add(id);
            todos.push({
                id, name: names[i], notes: notes[i], status: status[i], tags: tags(tagNames[i]),
                due: iso(due[i]), defer: iso(act[i]), completed: iso(done[i]), canceled: iso(canc[i]),
                projectId: idOf(() => items[i].project()),
                areaId: idOf(() => items[i].area()),
                inbox: inbox.has(id), today: today.has(id), someday: someday.has(id),
            });
        });
    });
    todos.sort((a, b) => (order[a.id] ?? 1e9) - (order[b.id] ?? 1e9));

    return { areas, projects, todos };
}

// Runs inside OmniFocus (Omni Automation), not in JXA.
function importIntoOmniFocus(data) {
    const now = new Date();
    const d = s => (s ? new Date(s) : null);

    const existing = new Set(flattenedProjects.map(p => p.name));
    const dupes = data.projects.filter(p => existing.has(p.name)).map(p => p.name);
    if (dupes.length) return "Aborted: OmniFocus already has projects named " + dupes.join(", ") + ". Already imported?";

    const tagByName = {};
    flattenedTags.forEach(t => { tagByName[t.name] = t; });
    const tag = n => tagByName[n] || (tagByName[n] = new Tag(n));
    const somedayTag = tag("Someday");
    somedayTag.status = Tag.Status.OnHold;

    const folders = {};
    data.areas.forEach(a => { folders[a.id] = new Folder(a.name); });

    const projects = {};
    data.projects.forEach(p => {
        const pr = new Project(p.name, folders[p.areaId] || null);
        pr.note = p.notes || "";
        if (p.due) pr.dueDate = d(p.due);
        if (p.defer && d(p.defer) > now) pr.deferDate = d(p.defer);
        pr.addTags(p.tags.map(tag));
        if (p.someday) pr.status = Project.Status.OnHold;
        if (p.status === "completed") pr.markComplete(d(p.completed));
        if (p.status === "canceled") pr.status = Project.Status.Dropped;
        projects[p.id] = pr;
    });

    // OmniFocus folders can't hold tasks, so loose area to-dos go into a single-action list per area.
    const singleActions = {};
    const singleActionList = (key, name, folder) => {
        if (!singleActions[key]) {
            const pr = new Project(name, folder);
            pr.containsSingletonActions = true;
            singleActions[key] = pr;
        }
        return singleActions[key];
    };

    let count = 0;
    data.todos.forEach(t => {
        let position;
        if (projects[t.projectId]) position = projects[t.projectId];
        else if (folders[t.areaId]) position = singleActionList(t.areaId, folders[t.areaId].name, folders[t.areaId]);
        else if (t.inbox) position = inbox.ending;
        else position = singleActionList("", "Single Actions", null);

        const task = new Task(t.name, position);
        task.note = t.notes || "";
        if (t.due) task.dueDate = d(t.due);
        if (t.status === "open" && t.defer && d(t.defer) > now) task.deferDate = d(t.defer);
        if (t.today && t.status === "open") task.flagged = true;
        task.addTags(t.tags.map(tag));
        if (t.someday && t.status === "open") task.addTag(somedayTag);
        if (t.status === "completed") task.markComplete(d(t.completed));
        if (t.status === "canceled") task.drop(false);
        count++;
    });

    return "Imported " + data.areas.length + " folders, " + data.projects.length + " projects, " +
        Object.keys(singleActions).length + " single-action lists, " + count + " tasks.";
}
