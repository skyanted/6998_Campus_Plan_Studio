import {NextResponse} from 'next/server';
import {authClient} from '@/lib/supabase';
export async function GET(request:Request){const url=new URL(request.url),code=url.searchParams.get('code');if(code){const db=await authClient();const {error}=await db.auth.exchangeCodeForSession(code);if(!error)return NextResponse.redirect(new URL('/',url.origin));}return NextResponse.redirect(new URL('/login',url.origin));}
