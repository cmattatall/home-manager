import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { api } from "./api";
import { Workbench } from "./Workbench";
import "./global.css";

const client = new QueryClient({
  defaultOptions: { queries: { retry: false, refetchOnWindowFocus: false } },
});
const root = createRoot(document.getElementById("root")!);

async function start() {
  const fragment = new URLSearchParams(location.hash.slice(1));
  const ticket = fragment.get("ticket");
  const registrationCandidate = fragment.get("register") ?? "";
  history.replaceState(null, "", location.pathname + location.search);
  let loginError: string | undefined;
  if (ticket) {
    try {
      await api("login", { method: "POST", body: JSON.stringify({ ticket }) });
    } catch (error) {
      loginError = (error as Error).message;
    }
  }
  client.clear();
  root.render(
    <StrictMode>
      <QueryClientProvider client={client}>
        <BrowserRouter key={crypto.randomUUID()}>
          <Workbench
            loginError={loginError}
            registrationCandidate={registrationCandidate}
          />
        </BrowserRouter>
      </QueryClientProvider>
    </StrictMode>,
  );
}

window.addEventListener("hashchange", () => void start());
void start();
