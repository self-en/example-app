const listEl = document.getElementById('todo-list');
const formEl = document.getElementById('todo-form');
const inputEl = document.getElementById('todo-input');
const tagsInputEl = document.getElementById('tags-input');
const tagFilterEl = document.getElementById('tag-filter');
const themeToggleEl = document.getElementById('theme-toggle');
const clockEl = document.getElementById('clock');

function updateClock() {
  clockEl.textContent = new Date().toLocaleTimeString();
}

updateClock();
setInterval(updateClock, 1000);

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  themeToggleEl.textContent = theme === 'dark' ? '☀️' : '🌙';
}

const storedTheme = localStorage.getItem('theme');
applyTheme(storedTheme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));

themeToggleEl.addEventListener('click', () => {
  const next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
  localStorage.setItem('theme', next);
  applyTheme(next);
});

async function loadTodos() {
  const tag = tagFilterEl.value;
  const res = await fetch(`/api/todos${tag ? `?tag=${encodeURIComponent(tag)}` : ''}`);
  render(await res.json());
}

async function refreshTagFilterOptions() {
  const res = await fetch('/api/tags');
  const tags = await res.json();
  const selected = tagFilterEl.value;
  tagFilterEl.innerHTML = '';
  const allOption = document.createElement('option');
  allOption.value = '';
  allOption.textContent = 'All';
  tagFilterEl.append(allOption);
  for (const { name, todo_count } of tags) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = `${name} (${todo_count})`;
    tagFilterEl.append(option);
  }
  tagFilterEl.value = tags.some((t) => t.name === selected) ? selected : '';
}

async function refresh() {
  await refreshTagFilterOptions();
  await loadTodos();
}

function render(todos) {
  listEl.innerHTML = '';
  for (const todo of todos) {
    const li = document.createElement('li');
    li.className = todo.completed ? 'completed' : '';

    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = todo.completed;
    checkbox.addEventListener('change', () => toggleTodo(todo.id, checkbox.checked));

    const span = document.createElement('span');
    span.textContent = todo.title;

    const tagsEl = document.createElement('span');
    tagsEl.className = 'tags';
    for (const tag of todo.tags || []) {
      const pill = document.createElement('span');
      pill.className = 'tag-pill';
      pill.textContent = tag;
      tagsEl.append(pill);
    }

    const deleteBtn = document.createElement('button');
    deleteBtn.textContent = '✕';
    deleteBtn.className = 'delete';
    deleteBtn.addEventListener('click', () => deleteTodo(todo.id));

    li.append(checkbox, span, tagsEl, deleteBtn);
    listEl.append(li);
  }
}

function parseTags(value) {
  return value
    .split(',')
    .map((tag) => tag.trim())
    .filter(Boolean);
}

async function addTodo(title, tags) {
  await fetch('/api/todos', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title, tags }),
  });
  await refresh();
}

async function toggleTodo(id, completed) {
  await fetch(`/api/todos/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ completed }),
  });
  await loadTodos();
}

async function deleteTodo(id) {
  await fetch(`/api/todos/${id}`, { method: 'DELETE' });
  await refresh();
}

formEl.addEventListener('submit', (event) => {
  event.preventDefault();
  const title = inputEl.value.trim();
  if (!title) return;
  const tags = parseTags(tagsInputEl.value);
  inputEl.value = '';
  tagsInputEl.value = '';
  addTodo(title, tags);
});

tagFilterEl.addEventListener('change', loadTodos);

refresh();
