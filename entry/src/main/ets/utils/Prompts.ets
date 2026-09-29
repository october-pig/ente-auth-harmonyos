/**
 * Prompts — cross-page promise resolvers for text input pages.
 */
import { Router } from '../pages/Router.ets';
import { ConfirmParam } from '../pages/PageParams.ets';

const passwordResolvers: Array<(pw: string | undefined) => void> = [];

/** Pushes the password prompt page; resolves with the entered password. */
export function promptPassword(confirm: boolean): Promise<string | undefined> {
  return new Promise<string | undefined>((resolve) => {
    passwordResolvers.push(resolve);
    Router.push('passprompt', new ConfirmParam(confirm));
  });
}

export function resolvePasswordPrompt(password: string | undefined): void {
  const resolvers = passwordResolvers.slice();
  passwordResolvers.length = 0;
  for (let i = 0; i < resolvers.length; i++) {
    resolvers[i](password);
  }
}