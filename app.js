const defaultPersonas = [
  {
    id: "mentor",
    name: "Mentor Max",
    description: "Supportive coach who explains step-by-step.",
    systemPrompt:
      "You are Mentor Max, a supportive AI coach. Be encouraging, clear, and practical. Use concise bullets when helpful.",
  },
  {
    id: "comedian",
    name: "Jester Joy",
    description: "Lighthearted and funny, but still helpful.",
    systemPrompt:
      "You are Jester Joy, a witty assistant. Keep responses useful, playful, and safe. Include at most one short joke per reply.",
  },
  {
    id: "coder",
    name: "Code Ninja",
    description: "Deep technical helper for developers.",
    systemPrompt:
      "You are Code Ninja, an expert software engineer. Give robust solutions, include code examples when asked, and call out tradeoffs.",
  },
  {
    id: "therapist",
    name: "Calm Companion",
    description: "Empathetic listener with gentle responses.",
    systemPrompt:
      "You are Calm Companion, a warm and empathetic conversational assistant. Listen first and respond with validation and gentle guidance.",
  },
  {
    id: "strategist",
    name: "Strategy Sage",
    description: "Analytical planner for business and life goals.",
    systemPrompt:
      "You are Strategy Sage, a strategic analyst. Provide structured plans with goals, risks, and next actions.",
  },
];

const state = {
  personas: [...defaultPersonas],
  activePersonaId: defaultPersonas[0].id,
  chatsByPersona: {},
};

const el = {
  personaList: document.getElementById("personaList"),
  activePersonaName: document.getElementById("activePersonaName"),
  activePersonaDesc: document.getElementById("activePersonaDesc"),
  messages: document.getElementById("messages"),
  userInput: document.getElementById("userInput"),
  chatForm: document.getElementById("chatForm"),
  clearChatBtn: document.getElementById("clearChatBtn"),
  apiKey: document.getElementById("apiKey"),
  model: document.getElementById("model"),
  mockMode: document.getElementById("mockMode"),
  customName: document.getElementById("customName"),
  customPrompt: document.getElementById("customPrompt"),
  addPersonaBtn: document.getElementById("addPersonaBtn"),
  messageTemplate: document.getElementById("messageTemplate"),
  themeToggle: document.getElementById("themeToggle"),
};

function getActivePersona() {
  return state.personas.find((p) => p.id === state.activePersonaId);
}

function getChat(personaId = state.activePersonaId) {
  if (!state.chatsByPersona[personaId]) {
    state.chatsByPersona[personaId] = [];
  }
  return state.chatsByPersona[personaId];
}

function renderPersonas() {
  el.personaList.innerHTML = "";

  state.personas.forEach((persona) => {
    const item = document.createElement("button");
    item.className = `persona-item ${persona.id === state.activePersonaId ? "active" : ""}`;
    item.innerHTML = `<h3>${persona.name}</h3><p>${persona.description}</p>`;
    item.addEventListener("click", () => {
      state.activePersonaId = persona.id;
      renderPersonas();
      renderActivePersonaHeader();
      renderMessages();
    });
    el.personaList.appendChild(item);
  });
}

function renderActivePersonaHeader() {
  const persona = getActivePersona();
  el.activePersonaName.textContent = persona.name;
  el.activePersonaDesc.textContent = persona.description;
}

function createMessageEl({ role, content, time }) {
  const node = el.messageTemplate.content.firstElementChild.cloneNode(true);
  node.classList.add(role);
  node.querySelector(".meta").textContent = `${role === "user" ? "You" : "AI"} · ${time}`;
  node.querySelector(".bubble").textContent = content;
  return node;
}

function renderMessages() {
  const chat = getChat();
  el.messages.innerHTML = "";

  if (chat.length === 0) {
    const hint = document.createElement("p");
    hint.className = "note";
    hint.textContent = "Start chatting with this persona...";
    el.messages.appendChild(hint);
    return;
  }

  chat.forEach((msg) => {
    el.messages.appendChild(createMessageEl(msg));
  });
  el.messages.scrollTop = el.messages.scrollHeight;
}

function addMessage(role, content, personaId = state.activePersonaId) {
  getChat(personaId).push({
    role,
    content,
    time: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
  });

  if (personaId === state.activePersonaId) {
    renderMessages();
  }
}

function buildResponsesInput(persona, chat, userText) {
  const input = [{ role: "system", content: persona.systemPrompt }];

  chat.forEach((msg) => {
    input.push({ role: msg.role, content: msg.content });
  });

  input.push({ role: "user", content: userText });
  return input;
}

async function queryOpenAI(userText, persona) {
  const key = el.apiKey.value.trim();
  if (!key) {
    throw new Error("Missing API key. Add your OpenAI API key or enable demo mode.");
  }

  const chat = getChat();
  const body = {
    model: el.model.value,
    input: buildResponsesInput(persona, chat, userText),
  };

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${key}`,
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`OpenAI API error: ${response.status} ${errorText}`);
  }

  const data = await response.json();
  return data.output_text || "I could not generate a response.";
}

function mockReply(userText, persona) {
  const shortPrompt = persona.systemPrompt.slice(0, 80).replace(/\.$/, "");
  return `(${persona.name} demo mode) You said: "${userText}"\n\nPersona behavior: ${shortPrompt}...\n\nTurn off demo mode and add an API key for real AI responses.`;
}

async function handleSend(event) {
  event.preventDefault();
  const text = el.userInput.value.trim();
  if (!text) return;

  const persona = getActivePersona();
  addMessage("user", text);
  el.userInput.value = "";

  addMessage("assistant", "Thinking...");
  const chat = getChat();

  try {
    const reply = el.mockMode.checked
      ? mockReply(text, persona)
      : await queryOpenAI(text, persona);

    chat.pop();
    addMessage("assistant", reply);
  } catch (error) {
    chat.pop();
    addMessage("assistant", `Error: ${error.message}`);
  }
}

function handleAddPersona() {
  const name = el.customName.value.trim();
  const systemPrompt = el.customPrompt.value.trim();

  if (!name || !systemPrompt) {
    alert("Please provide both a name and a persona prompt.");
    return;
  }

  const id = `custom-${Date.now()}`;
  state.personas.push({
    id,
    name,
    description: "Custom persona",
    systemPrompt,
  });

  el.customName.value = "";
  el.customPrompt.value = "";
  state.activePersonaId = id;
  renderPersonas();
  renderActivePersonaHeader();
  renderMessages();
}

function handleClearChat() {
  state.chatsByPersona[state.activePersonaId] = [];
  renderMessages();
}

function toggleTheme() {
  const dark = document.body.classList.toggle("dark");
  el.themeToggle.textContent = dark ? "☀️" : "🌙";
}

el.chatForm.addEventListener("submit", handleSend);
el.addPersonaBtn.addEventListener("click", handleAddPersona);
el.clearChatBtn.addEventListener("click", handleClearChat);
el.themeToggle.addEventListener("click", toggleTheme);

renderPersonas();
renderActivePersonaHeader();
renderMessages();
