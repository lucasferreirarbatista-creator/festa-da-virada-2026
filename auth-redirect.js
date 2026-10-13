(() => {
  const hash = new URLSearchParams(window.location.hash.slice(1));
  const query = new URLSearchParams(window.location.search);
  const type = hash.get("type") || query.get("type");
  const hasAuthResult = Boolean(
    hash.get("access_token") ||
    hash.get("error_code") ||
    hash.get("error_description") ||
    query.get("token_hash")
  );

  if (!hasAuthResult || !["invite", "recovery", "signup"].includes(type)) return;

  const destination = new URL("./definir-senha.html", window.location.href);
  destination.search = window.location.search;
  destination.hash = window.location.hash;
  window.location.replace(destination.toString());
})();
