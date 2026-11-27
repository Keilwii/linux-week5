// sends the message to /viikko5/api/chat and shows the reply as it streams in
const base = document.body.dataset.base || "";
const form = document.getElementById("chat-form");
const input = document.getElementById("message");
const sendBtn = document.getElementById("send");
const list = document.getElementById("messages");
const empty = document.getElementById("empty");

function addMessage(role, text) {
    const div = document.createElement("div");
    div.className = "msg " + role;
    const who = document.createElement("span");
    who.className = "who";
    who.textContent = role === "user" ? "You" : "Model";
    const p = document.createElement("p");
    p.textContent = text;
    div.append(who, p);
    list.append(div);
    empty.hidden = true;
    div.scrollIntoView({ block: "end" });
    return p;
}

async function send(text) {
    addMessage("user", text);
    const out = addMessage("assistant", "…");
    sendBtn.disabled = true;
    let got = "";
    try {
        const resp = await fetch(base + "/api/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message: text }),
        });
        if (!resp.ok) {
            const data = await resp.json().catch(() => ({}));
            throw new Error(data.error || "HTTP " + resp.status);
        }
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buf = "";
        for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            buf += decoder.decode(value, { stream: true });
            let nl;
            while ((nl = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (!line) continue;
                const ev = JSON.parse(line);
                if (ev.token) {
                    got += ev.token;
                    out.textContent = got;
                }
                if (ev.error) throw new Error(ev.error);
            }
        }
    } catch (err) {
        out.textContent = (got ? got + "\n\n" : "") + "Error: " + err.message;
        out.parentElement.classList.add("failed");
    } finally {
        sendBtn.disabled = false;
        input.focus();
    }
}

form.addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text || sendBtn.disabled) return;
    input.value = "";
    send(text);
});

input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        form.requestSubmit();
    }
});
