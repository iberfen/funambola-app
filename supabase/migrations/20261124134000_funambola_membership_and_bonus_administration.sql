alter table public.bonus_packs
  add column adjusted_sessions integer check (adjusted_sessions >= 0),
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references auth.users(id);

create policy "Admins read daily bonus uses" on public.bonus_daily_uses
  for select to authenticated using ((select public.is_admin()));

create or replace view public.bonus_status with (security_invoker=true) as
select p.id, p.user_id, p.purchased_at, p.expires_at, p.total_sessions, p.price_eur,
  greatest(0, coalesce(p.adjusted_sessions,p.total_sessions) - u.used) as remaining_sessions,
  case when p.cancelled_at is not null then 'cancelled'
       when now() >= p.expires_at then 'expired'
       when coalesce(p.adjusted_sessions,p.total_sessions) <= u.used then 'exhausted'
       when p.purchased_at > now() then 'scheduled'
       when now() >= p.expires_at - interval '15 days' then 'expiring_soon'
       else 'active' end as status,
  u.used as consumed_sessions, p.cancelled_at
from public.bonus_packs p cross join lateral (
  select (select count(*) from public.bonus_uses b where b.pack_id=p.id)
       + (select count(*) from public.bonus_daily_uses d where d.pack_id=p.id) as used
) u;
revoke all on public.bonus_status from public, anon;
grant select on public.bonus_status to authenticated;

create table public.bonus_admin_history (
  id bigint generated always as identity primary key,
  pack_id uuid not null references public.bonus_packs(id),
  changed_at timestamptz not null default now(),
  changed_by uuid not null,
  action text not null check(action in ('edited','cancelled')),
  previous jsonb not null,
  current_value jsonb not null
);
alter table public.bonus_admin_history enable row level security;
revoke all on public.bonus_admin_history from public, anon, authenticated;
grant select on public.bonus_admin_history to authenticated;
create policy "Owners and admins read bonus history" on public.bonus_admin_history
  for select to authenticated using (exists(select 1 from public.bonus_packs b where b.id=pack_id));

create function public.manage_funambono(p_id uuid, p_remaining integer, p_expiry timestamptz, p_cancel boolean, p_expected_used bigint)
returns void language plpgsql security definer set search_path='' as $fn$
declare
  old_pack public.bonus_packs%rowtype;
  new_pack public.bonus_packs%rowtype;
  used bigint;
  owner_id uuid;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode='42501'; end if;
  select user_id into strict owner_id from public.bonus_packs where id=p_id;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner_id::text,0));
  select * into strict old_pack from public.bonus_packs where id=p_id for update;
  if old_pack.cancelled_at is not null then raise exception 'El bono ya está anulado'; end if;
  select consumed_sessions into used from public.bonus_status where id=p_id;
  if p_cancel is true then
    update public.bonus_packs set cancelled_at=now(), cancelled_by=auth.uid()
      where id=p_id returning * into new_pack;
  else
    if used is distinct from p_expected_used then raise exception 'El saldo ha cambiado. Vuelve a abrir el bono.'; end if;
    if p_remaining is null or p_remaining not between 0 and 10000 or p_expiry is null or p_expiry <= old_pack.purchased_at then
      raise exception 'Comprueba las sesiones y la fecha de caducidad';
    end if;
    update public.bonus_packs set adjusted_sessions=used+p_remaining, expires_at=p_expiry
      where id=p_id returning * into new_pack;
  end if;
  insert into public.bonus_admin_history(pack_id,changed_by,action,previous,current_value)
    values(p_id,auth.uid(),case when p_cancel then 'cancelled' else 'edited' end,
      jsonb_build_object('remaining',greatest(0,coalesce(old_pack.adjusted_sessions,old_pack.total_sessions)-used),'expiry',old_pack.expires_at),
      jsonb_build_object('remaining',greatest(0,coalesce(new_pack.adjusted_sessions,new_pack.total_sessions)-used),'expiry',new_pack.expires_at));
end
$fn$;
revoke all on function public.manage_funambono(uuid,integer,timestamptz,boolean,bigint) from public, anon;
grant execute on function public.manage_funambono(uuid,integer,timestamptz,boolean,bigint) to authenticated;

CREATE OR REPLACE FUNCTION public.consume_my_funambono()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
    v_today date := (clock_timestamp() AT TIME ZONE 'Europe/Madrid')::date;
      v_pack uuid;
      BEGIN
        IF v_user IS NULL THEN
            RAISE EXCEPTION 'Debes iniciar sesión';
              END IF;

                IF NOT EXISTS (
                    SELECT 1 FROM public.profiles
                        WHERE id = v_user
                              AND access_status = 'active'
                                    AND member_status = 'active'
                                          AND membership_type = 'occasional'
                                            ) THEN
                                                RAISE EXCEPTION 'Solo los socios eventuales autorizados pueden consumir Funámbonos';
                                                  END IF;

                                                    PERFORM pg_catalog.pg_advisory_xact_lock(
                                                        pg_catalog.hashtextextended(v_user::text, 0)
                                                          );

                                                            IF EXISTS (
                                                                SELECT 1 FROM public.bonus_daily_uses
                                                                    WHERE user_id = v_user AND used_on = v_today
                                                                      ) THEN
                                                                          RAISE EXCEPTION 'Ya has utilizado tu Funámbono hoy';
                                                                            END IF;

                                                                              SELECT bp.id INTO v_pack
                                                                                FROM public.bonus_packs bp
                                                                                  WHERE bp.user_id = v_user
                                                                                      AND bp.cancelled_at IS NULL AND bp.purchased_at <= clock_timestamp()
                                                                                          AND bp.expires_at > clock_timestamp()
                                                                                              AND coalesce(bp.adjusted_sessions,bp.total_sessions) > (
                                                                                                    (SELECT count(*) FROM public.bonus_uses bu WHERE bu.pack_id = bp.id)
                                                                                                          +
                                                                                                                (SELECT count(*) FROM public.bonus_daily_uses du WHERE du.pack_id = bp.id)
                                                                                                                    )
                                                                                                                      ORDER BY bp.expires_at, bp.purchased_at, bp.id
                                                                                                                        LIMIT 1 FOR UPDATE;

                                                                                                                          IF v_pack IS NULL THEN
                                                                                                                              RAISE EXCEPTION 'No tienes un Funámbono vigente con sesiones disponibles';
                                                                                                                                END IF;

                                                                                                                                  INSERT INTO public.bonus_daily_uses(user_id, pack_id, used_on)
                                                                                                                                    VALUES (v_user, v_pack, v_today);

                                                                                                                                      RETURN 'Sesión descontada correctamente';
                                                                                                                                      END;
                                                                                                                                      $function$;

CREATE OR REPLACE FUNCTION public.mark_my_bonus_session(p_training_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
          DECLARE v_user uuid := auth.uid(); v_start timestamptz;
          BEGIN
           IF v_user IS NULL THEN RAISE EXCEPTION 'Inicia sesión'; END IF;
            IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_user AND access_status='active')
             THEN RAISE EXCEPTION 'Acceso no aprobado'; END IF;
              SELECT starts_at INTO v_start FROM public.trainings WHERE id=p_training_id;
               IF v_start IS NULL OR v_start<=now() THEN RAISE EXCEPTION 'El entrenamiento ya ha comenzado o no existe'; END IF;
                IF NOT EXISTS (
                  SELECT 1 FROM public.bonus_packs bp WHERE bp.user_id=v_user
                    AND bp.cancelled_at IS NULL AND bp.purchased_at<=v_start AND bp.expires_at>v_start
                      AND coalesce(bp.adjusted_sessions,bp.total_sessions) > ((SELECT count(*) FROM public.bonus_uses bu WHERE bu.pack_id=bp.id)+(SELECT count(*) FROM public.bonus_daily_uses du WHERE du.pack_id=bp.id))
                       ) THEN RAISE EXCEPTION 'No tienes un Funámbono vigente con sesiones disponibles'; END IF;
                        IF EXISTS (
                          SELECT 1 FROM public.bonus_marks bm
                            JOIN public.trainings t ON t.id=bm.training_id
                              WHERE bm.user_id=v_user AND (t.starts_at AT TIME ZONE 'Europe/Madrid')::date =
                                      (v_start AT TIME ZONE 'Europe/Madrid')::date
                                       ) THEN RETURN 'Ya tienes una sesión marcada para ese día'; END IF;
                                        INSERT INTO public.bonus_marks(user_id,training_id) VALUES(v_user,p_training_id)
                                         ON CONFLICT (user_id,training_id) DO NOTHING;
                                          RETURN 'Sesión marcada correctamente. Descuento pendiente de activar.';
                                          END; $function$;

CREATE OR REPLACE FUNCTION public.validate_bonus_use()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
                                    declare
                                      pack_record record;
                                        used_count integer;
                                        begin
                                          select user_id, coalesce(adjusted_sessions,total_sessions) AS total_sessions, expires_at, cancelled_at
                                            into pack_record
                                              from public.bonus_packs
                                                where id = new.pack_id
                                                  for update;

                                                    if not found then
                                                        raise exception 'Funambono no encontrado';
                                                          end if;

                                                            if pack_record.cancelled_at is not null or now() >= pack_record.expires_at then
                                                                raise exception 'Funambono caducado. Contacta con los responsables de Funambola.';
                                                                  end if;

                                                                    select count(*) into used_count
                                                                      from public.bonus_uses
                                                                        where pack_id = new.pack_id;
 used_count := used_count + (select count(*) from public.bonus_daily_uses where pack_id=new.pack_id);

                                                                          if used_count >= pack_record.total_sessions then
                                                                              raise exception 'Funambono agotado. Contacta con los responsables de Funambola.';
                                                                                end if;

                                                                                  if not exists (
                                                                                      select 1 from public.training_participants
                                                                                          where training_id = new.training_id
                                                                                                and user_id = pack_record.user_id
                                                                                                  ) then
                                                                                                      raise exception 'El titular no esta inscrito en este entrenamiento';
                                                                                                        end if;

                                                                                                          return new;
                                                                                                          end;
                                                                                                          $function$;


create function public.save_membership(p_id uuid,p_joined date,p_expiry date,p_type text,p_months int,p_expected_updated timestamptz)
returns void language plpgsql security invoker set search_path='' as $fn$
declare
  madrid_today date := (now() at time zone 'Europe/Madrid')::date;
  current_dues public.membership_dues%rowtype;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode='42501'; end if;
  if p_type is null or p_type not in ('regular','occasional','unassigned')
     or p_months is null or p_months not in (0,1,6,12) then
    raise exception 'Tipo de socio o duración no válidos';
  end if;
  perform 1 from public.profiles where id=p_id for update;
  if not found then raise exception 'Socio inexistente'; end if;
  select * into current_dues from public.membership_dues where user_id=p_id for update;
  if current_dues.updated_at is distinct from p_expected_updated then
    raise exception 'La ficha ha cambiado. Vuelve a abrirla antes de guardar.';
  end if;
  if p_months > 0 then
    p_expiry := (greatest(p_expiry,madrid_today)+make_interval(months=>p_months))::date;
    p_joined := coalesce(p_joined,madrid_today);
  end if;
  if p_expiry < p_joined then raise exception 'El vencimiento debe ser igual o posterior al alta'; end if;
  update public.profiles set membership_type=p_type where id=p_id and membership_type is distinct from p_type;
  insert into public.membership_dues(user_id,joined_on,paid_through,configured_at,updated_at)
    values(p_id,p_joined,p_expiry,now(),now())
    on conflict(user_id) do update set joined_on=excluded.joined_on,paid_through=excluded.paid_through,updated_at=excluded.updated_at;
end
$fn$;
revoke all on function public.save_membership(uuid,date,date,text,int,timestamptz) from public, anon;
grant execute on function public.save_membership(uuid,date,date,text,int,timestamptz) to authenticated;

create or replace function funambola_private.notify_bonus_consumption()
returns trigger language plpgsql security definer set search_path='' as $fn$
begin
  insert into public.training_notifications(recipient_id,actor_id,message,category)
  select recipient.id, b.user_id,
    format('Funámbono de %s. Consumidas: %s. Restantes: %s. Caducidad: %s.%s',
      holder.full_name, b.consumed_sessions, b.remaining_sessions,
      to_char(b.expires_at at time zone 'Europe/Madrid','DD/MM/YYYY'),
      case when b.remaining_sessions=0 then ' Bono agotado.' else '' end), 'bonus'
  from public.bonus_status b
  join public.profiles holder on holder.id=b.user_id
  join public.profiles recipient on recipient.access_status='active'
    and (recipient.is_admin or recipient.id=b.user_id)
  left join public.funambola_notice_preferences prefs on prefs.user_id=recipient.id
  where b.id=new.pack_id and (prefs.user_id is null or 'bonus'=any(prefs.categories));
  return new;
end
$fn$;
revoke all on function funambola_private.notify_bonus_consumption() from public, anon, authenticated;
drop trigger funambola_notice_bonus on public.bonus_daily_uses;
create trigger funambola_notice_bonus after insert on public.bonus_daily_uses
  for each row execute function funambola_private.notify_bonus_consumption();
create trigger funambola_notice_manual_bonus after insert on public.bonus_uses
  for each row execute function funambola_private.notify_bonus_consumption();

create table funambola_private.bonus_expiry_deliveries (
  pack_id uuid not null references public.bonus_packs(id),
  expires_at timestamptz not null,
  recipient_id uuid not null,
  primary key(pack_id,expires_at,recipient_id)
);
alter table funambola_private.bonus_expiry_deliveries enable row level security;
create or replace function funambola_private.notify_expiring_bonuses()
returns void language sql security definer set search_path='' as $fn$
  with deliveries as (
    insert into funambola_private.bonus_expiry_deliveries
    select b.id,b.expires_at,p.id from public.bonus_status b
    join public.profiles p on p.access_status='active' and (p.id=b.user_id or p.is_admin)
    left join public.funambola_notice_preferences pref on pref.user_id=p.id
    where b.status='expiring_soon' and (pref.user_id is null or 'expiry'=any(pref.categories))
    on conflict do nothing returning *
  )
  insert into public.training_notifications(recipient_id,message,category)
  select d.recipient_id,format('Funámbono de %s próximo a caducar el %s. Consumidas: %s. Restantes: %s.',
    p.full_name,to_char(d.expires_at at time zone 'Europe/Madrid','DD/MM/YYYY'),
    b.consumed_sessions,b.remaining_sessions),'expiry'
  from deliveries d join public.bonus_status b on b.id=d.pack_id
  join public.profiles p on p.id=b.user_id;
$fn$;

create function funambola_private.notify_membership_dues()
returns void language sql security definer set search_path='' as $fn$
  with dates as (
    select d.user_id,d.paid_through,d.paid_through-(now() at time zone 'Europe/Madrid')::date as days
    from public.membership_dues d join public.profiles p on p.id=d.user_id
    where p.access_status='active' and d.paid_through is not null
  ), due as (
    insert into public.membership_alerts(user_id,due_on,alert_kind)
    select user_id,paid_through,case when days<0 then 'expired' when days=0 then 'due_today'
      when days<=3 then 'three_days' else 'seven_days' end
    from dates where days<=7
    on conflict do nothing returning *
  )
  insert into public.training_notifications(recipient_id,message,category)
  select p.id,format('Cuota de %s %s %s.',holder.full_name,
    case when due.alert_kind='expired' then 'vencida desde' else 'con vencimiento el' end,
    to_char(due.due_on,'DD/MM/YYYY')),'expiry'
  from due join public.profiles holder on holder.id=due.user_id
  join public.profiles p on p.access_status='active' and (p.id=due.user_id or p.is_admin);
$fn$;
revoke all on function funambola_private.notify_membership_dues() from public, anon, authenticated;
select cron.schedule('funambola-membership-expiry','5 8 * * *','select funambola_private.notify_membership_dues()');

-- Keep client privileges aligned with row policies and the administration RPC.
revoke truncate, trigger on public.profiles, public.bonus_packs, public.bonus_uses,
  public.bonus_daily_uses, public.membership_dues, public.membership_payments,
  public.membership_alerts, public.training_notifications from public, anon, authenticated;
revoke update on public.training_notifications from anon, authenticated;
grant update(read_at) on public.training_notifications to authenticated;
