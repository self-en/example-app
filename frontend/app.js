const listEl = document.getElementById('todo-list');
const formEl = document.getElementById('todo-form');
const inputEl = document.getElementById('todo-input');
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
  const res = await fetch('/api/todos');
  render(await res.json());
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

    const deleteBtn = document.createElement('button');
    deleteBtn.textContent = '✕';
    deleteBtn.className = 'delete';
    deleteBtn.addEventListener('click', () => deleteTodo(todo.id));

    li.append(checkbox, span, deleteBtn);
    listEl.append(li);
  }
}

async function addTodo(title) {
  await fetch('/api/todos', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title }),
  });
  await loadTodos();
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
  await loadTodos();
}

formEl.addEventListener('submit', (event) => {
  event.preventDefault();
  const title = inputEl.value.trim();
  if (!title) return;
  inputEl.value = '';
  addTodo(title);
});

loadTodos();
