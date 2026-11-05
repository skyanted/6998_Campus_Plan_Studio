import {NextResponse} from 'next/server';
import {authClient} from '@/lib/supabase';
export async function POST(request:Request){if(request.headers.get('origin')!==new URL(request.url).origin)return new Response('Invalid origin',{status:403});await (await authClient()).auth.signOut();return NextResponse.redirect(new URL('/login',request.url),303);}
