import { Table } from '../core/db.js';
import type { Id, Initiative, Project } from '../core/types.js';
import { newId } from '../core/util.js';
import { crud, type Deps } from './crud.js';

export function createProjects({ db, bus }: Deps) {
  const initiativeTable = new Table<Initiative>(db, 'initiatives', {
    id: 's', title: 's', notes: 's', status: 's', weight: 'n', horizon: 's', createdAt: 'n', updatedAt: 'n',
  }, () => bus.changed('initiatives'));
  const projectTable = new Table<Project>(db, 'projects', {
    id: 's', initiativeId: 's', title: 's', notes: 's', status: 's', color: 's', weight: 'n', createdAt: 'n', updatedAt: 'n',
  }, () => bus.changed('projects'));

  const initiatives = {
    ...crud<Initiative>(initiativeTable, (now) => ({ id: newId(), title: '', notes: '', status: 'active', weight: 1, horizon: null, createdAt: now, updatedAt: now }), ['title']),
    list: () => initiativeTable.where('ORDER BY weight DESC, title'),
    remove(id: Id) {
      initiativeTable.delete(id);
      bus.changed('projects');
    },
  };
  const projects = {
    ...crud<Project>(projectTable, (now) => ({ id: newId(), initiativeId: null, title: '', notes: '', status: 'active', color: null, weight: 1, createdAt: now, updatedAt: now }), ['title']),
    list: () => projectTable.where('ORDER BY weight DESC, title'),
    remove(id: Id) {
      projectTable.delete(id);
      bus.changed('tasks');
    },
  };
  return { initiatives, projects };
}
