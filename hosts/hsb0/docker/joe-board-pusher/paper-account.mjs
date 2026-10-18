// Shared by the pusher and official reader; never infer identity from a request.
export function configuredPaperAccount() {
  const account = process.env.IB_DESK_ACCOUNT;
  if (typeof account !== "string" || account !== account.trim() || !/^DU[A-Z0-9]+$/.test(account)) {
    throw new Error("IB_DESK_ACCOUNT must configure a paper account");
  }
  return account;
}
