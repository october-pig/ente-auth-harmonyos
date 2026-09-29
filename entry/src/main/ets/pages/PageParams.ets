/**
 * Typed navigation parameter holders (ArkTS forbids passing untyped object
 * literals; NavPathStack params are typed via these classes).
 */
import { Code } from '../models/Code';
import { SrpAttributes } from '../account/UserService';
import { KeyGenResult } from '../models/KeyAttributes';

export class LoginModeParam {
  isSignup: boolean;

  constructor(isSignup: boolean) {
    this.isSignup = isSignup;
  }
}

export class EmailFlowParam {
  isSignup: boolean;
  email: string;

  constructor(isSignup: boolean, email: string) {
    this.isSignup = isSignup;
    this.email = email;
  }
}

export class CodeParam {
  code: Code | undefined;

  constructor(code: Code | undefined) {
    this.code = code;
  }
}

export class SrpLoginParam {
  email: string;
  attrs: SrpAttributes;

  constructor(email: string, attrs: SrpAttributes) {
    this.email = email;
    this.attrs = attrs;
  }
}

export class KeyGenResultParam {
  result: KeyGenResult;
  revision: number;

  constructor(result: KeyGenResult, revision: number) {
    this.result = result;
    this.revision = revision;
  }
}

export class SessionIDParam {
  sessionID: string;

  constructor(sessionID: string) {
    this.sessionID = sessionID;
  }
}

export class CodesParam {
  codes: Code[];

  constructor(codes: Code[]) {
    this.codes = codes;
  }
}

export class ConfirmParam {
  confirm: boolean;

  constructor(confirm: boolean) {
    this.confirm = confirm;
  }
}

export class TagsParam {
  tags: string[];

  constructor(tags: string[]) {
    this.tags = tags;
  }
}