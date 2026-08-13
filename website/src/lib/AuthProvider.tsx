"use client";

import { onAuthStateChanged, signOut, type User } from "firebase/auth";
import { createContext, useContext, useEffect, useState } from "react";
import { auth } from "./firebaseClient";

interface AuthContextValue {
  user: User | null;
  loading: boolean;
  logOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue>({
  user: null,
  loading: true,
  logOut: async () => {},
});

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Same Firebase Auth project as the Flutter app (CLAUDE.md's Website
    // & Account/Tournament Rules decision: "Shared login... single
    // Firebase Auth identity across both, not a separate signup") - an
    // account created in the app can sign in here with the same
    // email/password, and vice versa.
    return onAuthStateChanged(auth, (firebaseUser) => {
      setUser(firebaseUser);
      setLoading(false);
    });
  }, []);

  return (
    <AuthContext.Provider value={{ user, loading, logOut: () => signOut(auth) }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}
