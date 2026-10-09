// Deploy with: supabase functions deploy admin-user-management
// Configure SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY as Edge Function secrets.
// The service-role key must never be shipped to the browser.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const respond = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return respond(405, { success: false, message: 'Method not allowed' })

  const url = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const authHeader = req.headers.get('Authorization')
  if (!url || !serviceKey || !authHeader) return respond(401, { success: false, message: 'Authentication required' })

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const token = authHeader.replace(/^Bearer\s+/i, '')
  const { data: callerData, error: callerError } = await admin.auth.getUser(token)
  if (callerError || !callerData.user) return respond(401, { success: false, message: 'Invalid session' })

  const { data: caller, error: roleError } = await admin.from('profiles')
    .select('id, role, active').eq('id', callerData.user.id).single()
  if (roleError || !caller || caller.role !== 'Admin' || !caller.active) {
    return respond(403, { success: false, message: 'Administrator access required' })
  }

  let body: Record<string, unknown>
  try { body = await req.json() } catch { return respond(400, { success: false, message: 'Invalid request body' }) }
  const action = body.action
  if (action === 'create') {
    const username = typeof body.username === 'string' ? body.username.trim() : ''
    const password = typeof body.password === 'string' ? body.password : ''
    const role = body.role === 'Admin' ? 'Admin' : 'User'
    if (!/^[a-zA-Z0-9._-]{3,40}$/.test(username)) return respond(400, { success: false, message: 'Username must be 3–40 characters using letters, numbers, dot, underscore or hyphen.' })
    if (password.length < 10 || password.length > 128) return respond(400, { success: false, message: 'Password must be at least 10 characters and no more than 128.' })
    const email = username.toLowerCase() + '@visitlog.app'
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { username },
    })
    if (createError || !created.user) return respond(400, { success: false, message: createError?.message || 'Unable to create account' })
    const { error: profileError } = await admin.from('profiles').update({ username, role, active: true }).eq('id', created.user.id)
    if (profileError) {
      await admin.auth.admin.deleteUser(created.user.id)
      return respond(500, { success: false, message: 'Profile setup failed; the new account was rolled back.' })
    }
    return respond(200, { success: true })
  }

  if (action === 'reset_password') {
    const userId = typeof body.user_id === 'string' ? body.user_id : ''
    const password = typeof body.password === 'string' ? body.password : ''
    if (!userId) return respond(400, { success: false, message: 'User ID is required' })
    if (password.length < 10 || password.length > 128) return respond(400, { success: false, message: 'Password must be at least 10 characters and no more than 128.' })
    const { error } = await admin.auth.admin.updateUserById(userId, { password })
    if (error) return respond(400, { success: false, message: error.message })
    return respond(200, { success: true })
  }

  if (action === 'change_username') {
    const userId = typeof body.user_id === 'string' ? body.user_id : ''
    const username = typeof body.username === 'string' ? body.username.trim() : ''
    if (!userId || !/^[a-zA-Z0-9._-]{3,40}$/.test(username)) return respond(400, { success: false, message: 'Enter a valid username (3–40 letters, numbers, dot, underscore or hyphen).' })
    const email = username.toLowerCase() + '@visitlog.app'
    const { data: existing } = await admin.from('profiles').select('id').ilike('username', username).neq('id', userId).maybeSingle()
    if (existing) return respond(409, { success: false, message: 'That username is already in use.' })
    const { error: authError } = await admin.auth.admin.updateUserById(userId, { email, email_confirm: true, user_metadata: { username } })
    if (authError) return respond(400, { success: false, message: authError.message })
    const { error: profileError } = await admin.from('profiles').update({ username }).eq('id', userId)
    if (profileError) return respond(500, { success: false, message: profileError.message })
    return respond(200, { success: true })
  }

  return respond(400, { success: false, message: 'Unknown action' })
})
